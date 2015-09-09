using ObjFileBase

global debugger_ans = nothing
reset_ans() = global debugger_ans = nothing

cxx"""
class CommandObjectJuliaCallback : public lldb_private::CommandObjectRaw
{
public:
  CommandObjectJuliaCallback(lldb_private::CommandInterpreter &interpreter,
    const char *name,
    const char *help,
    const char *syntax,
    uint32_t flags,
    jl_function_t *F) :
    CommandObjectRaw (interpreter, name, help, syntax, flags),
    m_F(F)
  {
  }

  virtual ~CommandObjectJuliaCallback() {}

  virtual bool
  DoExecute (const char * command, lldb_private::CommandReturnObject &result)
  {
      result.SetStatus (lldb::eReturnStatusSuccessFinishNoResult);
      $:( global debugger_ans = icxx"return m_F;"(icxx"return &m_exe_ctx;",icxx"return command;",icxx"return &result;"); nothing );
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

function retrieve_string(dbg,str)
  ptr = Gallium.target_call(dbg,:jl_bytestring_ptr,[str.ptr])
  size = Gallium.target_call(dbg,:jl_bytestring_length,[str.ptr])
  bytestring(Gallium.target_read(dbg,convert(UInt64,ptr),size))
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
    if li == C_NULL
      return "invalid"
    end
    str = Gallium.call_prepared_entrypoint(dbg, ctx, entrypoint, Ptr{Void}[li])
    retrieve_string(dbg,str)
  end
end

function retrieve_repr
end
let entrypoint = nothing
  function retrieve_repr(dbg,ctx,val)
    if entrypoint === nothing
      entrypoint = Gallium.entrypoint_for_julia_expression(dbg,"x","""
      buf = IOBuffer()
      show(buf,x)
      takebuf_string(buf)
      """)
    end
    retrieve_string(dbg,
      Gallium.call_prepared_entrypoint(dbg, ctx, entrypoint, Ptr{Void}[convert(UInt64,val)]))
  end
end

function ReadObjectFile(objfile)
    osize = icxx"$(objfile)->GetByteSize();"
    data = Array(UInt8,osize)
    icxx"$(objfile)->CopyData(0,$osize,$(pointer(data)));"
    buf = IOBuffer(data)
    oh = readmeta(buf)
end

cxxinclude(joinpath(dirname(@__FILE__),"ThreadPlanStepJulia.cpp"))
function initialize_commands(CI)
    dbg = icxx"&$CI.GetDebugger();"
    AddCommand(CI,"jbt") do ctx, input, result
      thread = current_thread(ctx)
      for frame in thread
        isJuliaFrame(frame) || continue
        println(STDOUT,getFrameDescription(dbg,icxx"*$ctx;",frame))
        #println(STDOUT,Gallium.dump(frame))
      end
      nothing
    end
    AddCommand(CI,"jp") do ctx, input, result
      input = bytestring(input)
      frame = Gallium.current_frame(ctx)
      vars = icxx"$frame->GetVariableList(false);"
      target = icxx"$frame->CalculateTarget();"
      vals = map(x->try; ValueObjectToJulia(icxx"$x.get();"); catch; nothing; end,
        map(var->icxx"$frame->GetValueObjectForFrameVariable($var,lldb::eNoDynamicValues);",vars))
      names = map(var->bytestring(icxx"$var->GetName();"),vars)
      validxs = find(x->x!==nothing,vals)
      otheridxs = collect(filter(x->!(x in validxs),1:length(names)))

      # Strip out '#'
      validxs = collect(filter(idx->!('#' in names[idx]),validxs))
      otheridxs = collect(filter(idx->!('#' in names[idx]),otheridxs))

      expression = """
      let
      $(join(map(name->string("local ",name),names[otheridxs]),'\n'))
      try
      $input
      catch e
      show(STDERR,e)
      end
      end
      """
      f = Gallium.entrypoint_for_julia_expression(dbg, names[validxs], expression)
      val = Gallium.call_prepared_entrypoint(dbg, icxx"*$ctx;", f,
        Ptr{Void}[convert(Ptr{Void},v.ref) for v in vals[validxs]])
      Base.Text(retrieve_repr(dbg,icxx"*$ctx;",val))
    end
    AddCommand(CI,"jobj") do ctx, input, result
      frame = current_frame(ctx)
      mod = getModuleForFrame(frame)
      @assert mod != C_NULL
      objf = icxx"$mod->GetObjectFile();"
      @assert objf != C_NULL
      ReadObjectFile(objf)
    end
    AddCommand(CI,"js") do ctx, input, result
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
      nothing
    end
end
