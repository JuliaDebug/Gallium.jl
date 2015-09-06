class ThreadPlanStepJulia : public lldb_private::ThreadPlanStepInRange {
private:
    lldb::BreakpointSP      m_break;
    lldb_private::StackID   m_jl_apply_id;
    lldb_private::StackID   m_jl_apply_parent_id;
    bool                    m_stepping_through_jl_apply;
public:
    ThreadPlanStepJulia(lldb_private::Thread &thread,
                       const lldb_private::AddressRange &range,
                       const lldb_private::SymbolContext &addr_context,
                       lldb::RunMode stop_others) :
        ThreadPlanStepInRange(thread,range,addr_context,stop_others,lldb_private::eLazyBoolYes,lldb_private::eLazyBoolYes)
    {
        SetCallbacks();
        SetBreakpoint();
    }

    ~ThreadPlanStepJulia() {
        m_thread.CalculateTarget()->RemoveBreakpointByID(m_break->GetID());
    }

    static bool ShouldStopHere (lldb_private::ThreadPlan *current_plan,
            lldb_private::Flags &flags, lldb::FrameComparison operation, void *baton)
    {
        bool should_stop_here = true;
        lldb_private::StackFrame *frame = current_plan->GetThread().GetStackFrameAtIndex(0).get();
        if (!frame)
            return true;

        auto sc = frame->GetSymbolContext (lldb::eSymbolContextModule);
        auto cu = sc.comp_unit;
        if (!cu)
            return false;
        auto symb = sc.symbol;
        return (
            (cu->GetLanguage() == lldb::eLanguageTypeJulia) /*||
            (symb->GetName() == lldb_private::ConstString("jl_apply")) ||
            (symb->GetName() == lldb_private::ConstString("jl_apply_generic"))
            */
        );
    }

    bool AtOurBreakpoint() {
        lldb::StopInfoSP stop_info_sp = GetPrivateStopInfo ();
        if (stop_info_sp)
        {
            lldb::StopReason reason = stop_info_sp->GetStopReason();
            if (reason == lldb::eStopReasonBreakpoint)
            {
                // If this is OUR breakpoint, we're fine, otherwise we don't know why this happened...
                lldb::BreakpointSiteSP site_sp (m_thread.GetProcess()->GetBreakpointSiteList().FindByID (stop_info_sp->GetValue()));
                if (site_sp && site_sp->IsBreakpointAtThisSite (m_break->GetID())) {
                    return true;
                }
            }
        }
        return false;
    }

    bool
    DoPlanExplainsStop (lldb_private::Event *event_ptr) {
        if (AtOurBreakpoint())
            return true;
        return ThreadPlanStepInRange::DoPlanExplainsStop(event_ptr);
    }

    // Replace by checking for DW_AT_artificial (see #6)
    bool startsWithJlCall(lldb_private::ConstString symbol)
    {
        const char *prefix = "jlcall";
        size_t prefixlen = strlen(prefix),
               symlen = symbol.GetLength();
        return symlen < prefixlen ? false : strncmp(symbol.GetCString(), prefix, prefixlen) == 0;
    }

    bool
    ShouldStop (lldb_private::Event *event_ptr)
    {
        lldb_private::Log *log(lldb_private::GetLogIfAllCategoriesSet (LIBLLDB_LOG_STEP));

        lldb_private::StackID cur_frame_id = m_thread.GetStackFrameAtIndex(0)->GetStackID();
        lldb_private::StackID parent_frame_id = m_thread.GetStackFrameAtIndex(1)->GetStackID();
        if (AtOurBreakpoint()) {
            // Sometimes, even though we're at our breakpoint lldb thinks we're
            // still in the parent frame, so we need to check
            lldb_private::StackFrame *frame = m_thread.GetStackFrameAtIndex(0).get();
            assert(frame);

            auto sc = frame->GetSymbolContext (lldb::eSymbolContextSymbol);
            auto symb = sc.symbol;
            if (symb->GetName() != lldb_private::ConstString("jl_apply")) {
                m_jl_apply_parent_id = cur_frame_id;
            } else {
                m_jl_apply_id = cur_frame_id;
                m_jl_apply_parent_id = parent_frame_id;
            }
            m_stepping_through_jl_apply = true;
            SetNextBranchBreakpoint();
            m_thread.DiscardThreadPlansUpToPlan(m_sub_plan_sp);
            m_sub_plan_sp.reset();
            if (log) {
                lldb_private::StreamFile o(stdout,false);
                log->Printf("Stepping through jl_apply");
                log->Printf("Step Thread is ");
                m_thread.GetStatus (o, 0, 10, 0);
            }
            return false;
        }
        if (m_stepping_through_jl_apply) {
            if (cur_frame_id == m_jl_apply_id ||
                     cur_frame_id == m_jl_apply_parent_id ||
                     parent_frame_id == m_jl_apply_parent_id) {
                SetNextBranchBreakpoint();
                if (log)
                    log->Printf("Continuing to step through jl_apply");
                return false;
            } else if (log) {
                lldb_private::StreamFile o(stdout,false);
                log->Printf("jl_apply frame was ");
                m_jl_apply_id.Dump(&o);
                log->Printf("jl_apply parent frame was ");
                m_jl_apply_parent_id.Dump(&o);
                log->Printf("current frame is ");
                cur_frame_id.Dump(&o);
                log->Printf("current parent is ");
                parent_frame_id.Dump(&o);
                log->Printf("Thread is ");
                m_thread.GetStatus (o, 0, 10, 0);
            }
        }
        if (m_stepping_through_jl_apply) {
            if (log)
                log->Printf("Successfully stepped through jl_apply");
            m_stepping_through_jl_apply = false;
            m_jl_apply_id.Clear();
            m_jl_apply_parent_id.Clear();
        }
        // Check if we're currently in jlcall_, if so keep stepping
        auto sc = m_thread.GetStackFrameAtIndex(0)->GetSymbolContext (lldb::eSymbolContextSymbol);
        auto symb = sc.symbol;
        if (symb && startsWithJlCall(symb->GetName())) {
            SetNextBranchBreakpoint();
            if (log)
                log->Printf("Stepping through jlcall");
            if (m_sub_plan_sp) {
                m_thread.DiscardThreadPlansUpToPlan(m_sub_plan_sp);
                m_sub_plan_sp.reset();
            }
            return false;
        }
        return ThreadPlanStepInRange::ShouldStop(event_ptr);
    }

    void SetCallbacks() {
        lldb_private::ThreadPlanShouldStopHere::ThreadPlanShouldStopHereCallbacks callbacks(ThreadPlanStepJulia::ShouldStopHere, nullptr);
        SetShouldStopHereCallbacks (&callbacks, nullptr);
    }

    void SetBreakpoint() {
        m_break = m_thread.CalculateTarget()->CreateBreakpoint(
            NULL, NULL, "jl_apply", lldb::eFunctionNameTypeBase,
            lldb::eLanguageTypeC, lldb_private::eLazyBoolYes, true, false
        );
    }

    void
    GetDescription (lldb_private::Stream *s, lldb::DescriptionLevel level)
    {
        if (level == lldb::eDescriptionLevelBrief)
        {
            s->Printf("step julia");
            return;
        }

        s->Printf ("Stepping into julia frames");
    }
};
