cxx"""
class CommandObjectJuliaCallback : public lldb_private::CommandObjectParsed
{
public:
  CommandObjectJuliaCallback(lldb_private::CommandInterpreter &interpreter,
    const char *name,
    const char *help,
    const char *syntax,
    uint32_t flags,
    jl_function_t *F) :
    CommandObjectParsed (interpreter, name, help, syntax, flags),
    m_F(F)
  {
  }

  virtual ~CommandObjectJuliaCallback() {}

  virtual bool
  DoExecute (lldb_private::Args& command, lldb_private::CommandReturnObject &result)
  {
      result.SetStatus (lldb::eReturnStatusSuccessFinishNoResult);
      $:( icxx"return m_F;"(icxx"return &m_exe_ctx;",icxx"return &result;"); nothing );
      return true;
  }
private:
  jl_function_t *m_F;
};
"""

AddCommand(CI,name,cmd) = @assert icxx"$CI.AddCommand($(pointer(name)),$cmd,true);"

global command_functions = Function[]

function AddCommand(F::Function, CI, name; help = "", syntax = name)
  push!(command_functions,F)
  AddCommand(CI,name,icxx"""
  lldb::CommandObjectSP(new
    CommandObjectJuliaCallback($CI,$(pointer(name)),$(pointer(help)),$(pointer(syntax)),0,$(jpcpp"jl_function_t"(F))));
  """)
end

function getFrameDescription
end
let entrypoint = nothing
  function getFrameDescription(dbg,ctx,frame)
    if entrypoint === nothing
      entrypoint = Gallium.entrypoint_for_julia_expression(dbg,"f","""
      buf = IOBuffer()
      Base.print_specialized_signature(buf,f)
      takebuf_string(buf)
      """)
    end

    li = Gallium.getASTForFrame(frame).ptr
    str = Gallium.call_prepared_entrypoint(dbg, ctx, entrypoint, Ptr{Void}[li])
    ptr = Gallium.target_call(dbg,:jl_bytestring_ptr,[str.ptr])
    size = Gallium.target_call(dbg,:jl_bytestring_length,[str.ptr])
    bytestring(Gallium.target_read(dbg,convert(UInt64,ptr),size))
  end
end

cxxinclude(joinpath(dirname(@__FILE__),"ThreadPlanStepJulia.cpp"))
function initialize_commands(CI)
    dbg = icxx"&$CI.GetDebugger();"
    AddCommand(CI,"jbt") do ctx, result
      thread = current_thread(ctx)
      for frame in thread
        isJuliaFrame(frame) || continue
        println(STDOUT,getFrameDescription(dbg,icxx"*$ctx;",frame))
        #println(STDOUT,Gallium.dump(frame))
      end
    end
    AddCommand(CI,"js") do ctx, result
      thread = current_thread(ctx)
      frame = first(thread)
      icxx"""
        lldb::ThreadPlanSP new_plan_sp (new ThreadPlanStepJulia (*$thread,
              $frame->GetSymbolContext(lldb::eSymbolContextEverything).line_entry.range,
              $frame->GetSymbolContext(lldb::eSymbolContextEverything),
              lldb::eOnlyThisThread));
        $thread->QueueThreadPlan(new_plan_sp, false);
        lldb_private::Process *process = $ctx->GetProcessPtr();

        bool synchronous_execution = $CI.GetSynchronous();
        if (new_plan_sp)
        {
            new_plan_sp->SetIsMasterPlan (true);
            new_plan_sp->SetOkayToDiscard (false);

            process->GetThreadList().SetSelectedThreadByID ($thread->GetID());

            const uint32_t iohandler_id = process->GetIOHandlerID();

            lldb_private::StreamString stream;
            lldb_private::Error error;
            if (synchronous_execution)
                error = process->ResumeSynchronous (&stream);
            else
                error = process->Resume ();

            // There is a race condition where this thread will return up the call stack to the main command handler
            // and show an (lldb) prompt before HandlePrivateEvent (from PrivateStateThread) has
            // a chance to call PushProcessIOHandler().
            process->SyncIOHandler(iohandler_id, 2000);

            if (synchronous_execution)
            {
                // If any state changed events had anything to say, add that to the result
                if (stream.GetData())
                    $result->AppendMessage(stream.GetData());

                process->GetThreadList().SetSelectedThreadByID ($thread->GetID());
                $result->SetDidChangeProcessState (true);
                $result->SetStatus (lldb::eReturnStatusSuccessFinishNoResult);
            }
            else
            {
                $result->SetStatus (lldb::eReturnStatusSuccessContinuingNoResult);
            }
        }
      """
    end
end
