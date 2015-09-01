class ThreadPlanStepJulia : public lldb_private::ThreadPlanStepInRange {
public:
    ThreadPlanStepJulia(lldb_private::Thread &thread,
                       const lldb_private::AddressRange &range,
                       const lldb_private::SymbolContext &addr_context,
                       lldb::RunMode stop_others) :
        ThreadPlanStepInRange(thread,range,addr_context,stop_others,lldb_private::eLazyBoolYes,lldb_private::eLazyBoolYes)
    {
        SetCallbacks();
    }

    static bool ShouldStopHere (lldb_private::ThreadPlan *current_plan,
            lldb_private::Flags &flags, lldb::FrameComparison operation, void *baton)
    {
        bool should_stop_here = true;
        lldb_private::StackFrame *frame = current_plan->GetThread().GetStackFrameAtIndex(0).get();
        if (!frame)
            return true;

        auto cu = frame->GetSymbolContext (lldb::eSymbolContextModule).comp_unit;
        if (!cu)
            return false;
        return cu->GetLanguage() ==
            lldb::eLanguageTypeJulia;
    }

    void SetCallbacks() {
        lldb_private::ThreadPlanShouldStopHere::ThreadPlanShouldStopHereCallbacks callbacks(ThreadPlanStepJulia::ShouldStopHere, nullptr);
        SetShouldStopHereCallbacks (&callbacks, nullptr);
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
