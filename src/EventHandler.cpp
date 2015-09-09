static size_t g_debugger_event_thread_stack_bytes = 8 * 1024 * 1024;
class JuliaEventHandler
{
public:
    lldb_private::Debugger *m_dbg;
    lldb_private::Broadcaster m_sync_broadcaster;
    JuliaEventHandler(lldb_private::Debugger *dbg) : m_dbg(dbg),
    m_sync_broadcaster (NULL, "lldb.julia.sync")
    {}

    enum {
        eBroadcastBitEventThreadIsListening
    };

    // TODO: This should be factored in Process.cpp
    void UpdateSelectedThread(lldb::ProcessSP process_sp) {
        // Lock the thread list so it doesn't change on us, this is the scope for the locker:
        {
            lldb_private::ThreadList &thread_list = process_sp->GetThreadList();
            lldb_private::Mutex::Locker locker (thread_list.GetMutex());

            lldb::ThreadSP curr_thread (thread_list.GetSelectedThread());
            lldb::ThreadSP thread;
            lldb::StopReason curr_thread_stop_reason = lldb::eStopReasonInvalid;
            if (curr_thread)
                curr_thread_stop_reason = curr_thread->GetStopReason();
            if (!curr_thread ||
                !curr_thread->IsValid() ||
                curr_thread_stop_reason == lldb::eStopReasonInvalid ||
                curr_thread_stop_reason == lldb::eStopReasonNone)
            {
                // Prefer a thread that has just completed its plan over another thread as current thread.
                lldb::ThreadSP plan_thread;
                lldb::ThreadSP other_thread;

                const size_t num_threads = thread_list.GetSize();
                size_t i;
                for (i = 0; i < num_threads; ++i)
                {
                    thread = thread_list.GetThreadAtIndex(i);
                    lldb::StopReason thread_stop_reason = thread->GetStopReason();
                    switch (thread_stop_reason)
                    {
                        case lldb::eStopReasonInvalid:
                        case lldb::eStopReasonNone:
                            break;

                        case lldb::eStopReasonSignal:
                        {
                            // Don't select a signal thread if we weren't going to stop at that
                            // signal.  We have to have had another reason for stopping here, and
                            // the user doesn't want to see this thread.
                            uint64_t signo = thread->GetStopInfo()->GetValue();
                            if (process_sp->GetUnixSignals()->GetShouldStop(signo))
                            {
                                if (!other_thread)
                                    other_thread = thread;
                            }
                            break;
                        }
                        case lldb::eStopReasonTrace:
                        case lldb::eStopReasonBreakpoint:
                        case lldb::eStopReasonWatchpoint:
                        case lldb::eStopReasonException:
                        case lldb::eStopReasonExec:
                        case lldb::eStopReasonThreadExiting:
                        case lldb::eStopReasonInstrumentation:
                            if (!other_thread)
                                other_thread = thread;
                            break;
                        case lldb::eStopReasonPlanComplete:
                            if (!plan_thread)
                                plan_thread = thread;
                            break;
                    }
                }
                if (plan_thread)
                    thread_list.SetSelectedThreadByID (plan_thread->GetID());
                else if (other_thread)
                    thread_list.SetSelectedThreadByID (other_thread->GetID());
                else
                {
                    if (curr_thread && curr_thread->IsValid())
                        thread = curr_thread;
                    else
                        thread = thread_list.GetThreadAtIndex(0);

                    if (thread)
                        thread_list.SetSelectedThreadByID (thread->GetID());
                }
            }
        }
    }

    void PrintProcessThreadStatus(lldb_private::Stream *strm, lldb::ProcessSP process_sp)
    {
        size_t num_thread_infos_dumped = 0;

        // You can't hold the thread list lock while calling Thread::GetStatus.  That very well might run code (e.g. if we need it
        // to get return values or arguments.)  For that to work the process has to be able to acquire it.  So instead copy the thread
        // ID's, and look them up one by one:

        uint32_t num_threads;
        std::vector<lldb::tid_t> thread_id_array;
        //Scope for thread list locker;
        {
            lldb_private::Mutex::Locker locker (process_sp->GetThreadList().GetMutex());
            lldb_private::ThreadList &curr_thread_list = process_sp->GetThreadList();
            num_threads = curr_thread_list.GetSize();
            uint32_t idx;
            thread_id_array.resize(num_threads);
            for (idx = 0; idx < num_threads; ++idx)
                thread_id_array[idx] = curr_thread_list.GetThreadAtIndex(idx)->GetID();
        }

        for (uint32_t i = 0; i < num_threads; i++)
        {
            lldb::ThreadSP thread_sp(process_sp->GetThreadList().FindThreadByID(thread_id_array[i]));
            if (thread_sp)
            {
                lldb::StopInfoSP stop_info_sp = thread_sp->GetStopInfo();
                if (stop_info_sp.get() == NULL || !stop_info_sp->IsValid())
                    continue;

                lldb::StackFrameSP top_frame = thread_sp->GetStackFrameAtIndex(0);

                strm->Printf("Thread #%u stopped",thread_sp->GetIndexID());
                if (top_frame) {
                    lldb_private::SymbolContext frame_sc(top_frame->GetSymbolContext (lldb::eSymbolContextLineEntry));
                    if (frame_sc.line_entry.line != 0 && frame_sc.line_entry.file)
                        strm->Printf(" at %s:%d",frame_sc.line_entry.file.GetCString(),frame_sc.line_entry.line);
                    strm->Printf("\n");
                    top_frame->GetStatus(*strm,false,true,NULL);
                }

            }
        }
    }

    bool
    HandleProcessStateChangedEvent (const lldb::EventSP &event_sp,
                                             lldb_private::Stream *stream)
    {
        lldb::ProcessSP process_sp = lldb_private::Process::ProcessEventData::GetProcessFromEvent(event_sp.get());

        if (!process_sp)
            return false;

        lldb::StateType event_state = lldb_private::Process::ProcessEventData::GetStateFromEvent (event_sp.get());
        if (event_state == lldb::eStateInvalid)
            return false;

        switch (event_state)
        {
            default:
            case lldb::eStateInvalid:
            case lldb::eStateUnloaded:
            case lldb::eStateAttaching:
            case lldb::eStateLaunching:
            case lldb::eStateStepping:
            case lldb::eStateDetached:
            case lldb::eStateConnected:
            case lldb::eStateRunning:
            case lldb::eStateExited:
            {
                bool pop = false;
                return lldb_private::Process::HandleProcessStateChangedEvent(event_sp, stream, pop);
            }
            case lldb::eStateStopped:
            case lldb::eStateCrashed:
            case lldb::eStateSuspended:
                // Make sure the program hasn't been auto-restarted:
                if (lldb_private::Process::ProcessEventData::GetRestartedFromEvent (event_sp.get()))
                {
                    // Don't print anything if we were silently restarted
                }
                else
                {
                    UpdateSelectedThread(process_sp);
                    // Drop the ThreadList mutex by here, since GetThreadStatus below might have to run code,
                    // e.g. for Data formatters, and if we hold the ThreadList mutex, then the process is going to
                    // have a hard time restarting the process.
                    if (stream)
                    {
                        lldb_private::Debugger &debugger = process_sp->GetTarget().GetDebugger();
                        // This is not a hard assert, just not something we handle here,
                        // so better to assert if something unexpected comes up and would otherwise be silent
                        assert(debugger.GetTargetList().GetSelectedTarget().get() == &process_sp->GetTarget());

                        /*const bool only_threads_with_stop_reason = true;
                        const uint32_t start_frame = 0;
                        const uint32_t num_frames = 1;
                        const uint32_t num_frames_with_source = 1;*/
                        process_sp->GetStatus(*stream);
                        PrintProcessThreadStatus(stream,process_sp);
                    }

                }
                break;
        }

        return true;
    }

    void JuliaEventHandlerLoop()
    {

        lldb_private::Listener& listener(m_dbg->GetListener());
        lldb_private::ConstString broadcaster_class_target(lldb_private::Target::GetStaticBroadcasterClass());
        lldb_private::ConstString broadcaster_class_process(lldb_private::Process::GetStaticBroadcasterClass());
        lldb_private::ConstString broadcaster_class_thread(lldb_private::Thread::GetStaticBroadcasterClass());
        lldb_private::BroadcastEventSpec target_event_spec (broadcaster_class_target,
                                              lldb_private::Target::eBroadcastBitBreakpointChanged);

        lldb_private::BroadcastEventSpec process_event_spec (broadcaster_class_process,
                                               lldb_private::Process::eBroadcastBitStateChanged   |
                                               lldb_private::Process::eBroadcastBitSTDOUT         |
                                               lldb_private::Process::eBroadcastBitSTDERR);

        lldb_private::BroadcastEventSpec thread_event_spec (broadcaster_class_thread,
                                              lldb_private::Thread::eBroadcastBitStackChanged     |
                                              lldb_private::Thread::eBroadcastBitThreadSelected   );

        listener.StartListeningForEventSpec (*m_dbg, target_event_spec);
        listener.StartListeningForEventSpec (*m_dbg, process_event_spec);
        listener.StartListeningForEventSpec (*m_dbg, thread_event_spec);
        listener.StartListeningForEvents (&m_dbg->GetCommandInterpreter(),
                                          lldb_private::CommandInterpreter::eBroadcastBitQuitCommandReceived      |
                                          lldb_private::CommandInterpreter::eBroadcastBitAsynchronousOutputData   |
                                          lldb_private::CommandInterpreter::eBroadcastBitAsynchronousErrorData    );

        m_sync_broadcaster.BroadcastEvent(eBroadcastBitEventThreadIsListening);

        bool done = false;
        while (!done)
        {
            lldb::EventSP event_sp;
            if (listener.WaitForEvent(NULL, event_sp))
            {
                if (event_sp)
                {
                    lldb_private::Broadcaster *broadcaster = event_sp->GetBroadcaster();
                    if (broadcaster)
                    {
                        uint32_t event_type = event_sp->GetType();
                        lldb_private::ConstString broadcaster_class (broadcaster->GetBroadcasterClass());
                        if (broadcaster_class == broadcaster_class_process)
                        {
                            lldb::StreamSP output_stream_sp = m_dbg->GetAsyncOutputStream();
                            HandleProcessStateChangedEvent(event_sp,output_stream_sp.get());
                        }
                        else if (broadcaster_class == broadcaster_class_target)
                        {
                            if (lldb_private::Breakpoint::BreakpointEventData::GetEventDataFromEvent(event_sp.get()))
                            {
                                m_dbg->HandleBreakpointEvent (event_sp);
                            }
                        }
                        else if (broadcaster_class == broadcaster_class_thread)
                        {
                            //m_dbg->HandleThreadEvent (event_sp);
                        }
                        else if (broadcaster == &m_dbg->GetCommandInterpreter())
                        {
                            if (event_type & lldb_private::CommandInterpreter::eBroadcastBitQuitCommandReceived)
                            {
                                done = true;
                            }
                            else if (event_type & lldb_private::CommandInterpreter::eBroadcastBitAsynchronousErrorData)
                            {
                                const char *data = reinterpret_cast<const char *>(lldb_private::EventDataBytes::GetBytesFromEvent (event_sp.get()));
                                if (data && data[0])
                                {
                                    lldb::StreamSP error_sp (m_dbg->GetAsyncErrorStream());
                                    if (error_sp)
                                    {
                                        error_sp->PutCString(data);
                                        error_sp->Flush();
                                    }
                                }
                            }
                            else if (event_type & lldb_private::CommandInterpreter::eBroadcastBitAsynchronousOutputData)
                            {
                                const char *data = reinterpret_cast<const char *>(lldb_private::EventDataBytes::GetBytesFromEvent (event_sp.get()));
                                if (data && data[0])
                                {
                                    lldb::StreamSP output_sp (m_dbg->GetAsyncOutputStream());
                                    if (output_sp)
                                    {
                                        output_sp->PutCString(data);
                                        output_sp->Flush();
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    static lldb::thread_result_t
    EventHandlerThread (lldb::thread_arg_t arg)
    {
        ((JuliaEventHandler *)arg)->JuliaEventHandlerLoop();
        return NULL;
    }

    bool
    StartJuliaEventHandlerThread()
    {
        // We must synchronize with the DefaultEventHandler() thread to ensure
        // it is up and running and listening to events before we return from
        // this function. We do this by listening to events for the
        // eBroadcastBitEventThreadIsListening from the m_sync_broadcaster
        lldb_private::Listener listener("lldb.julia.event-handler");
        listener.StartListeningForEvents(&m_sync_broadcaster, eBroadcastBitEventThreadIsListening);

        // Use larger 8MB stack for this thread
        lldb_private::ThreadLauncher::LaunchThread("lldb.julia.event-handler", EventHandlerThread,
                                                              this,
                                                              NULL,
                                                              g_debugger_event_thread_stack_bytes);

        // Make sure DefaultEventHandler() is running and listening to events before we return
        // from this function. We are only listening for events of type
        // eBroadcastBitEventThreadIsListening so we don't need to check the event, we just need
        // to wait an infinite amount of time for it (NULL timeout as the first parameter)
        lldb::EventSP event_sp;
        //listener.WaitForEvent(NULL, event_sp);
        return true;
    }
};
