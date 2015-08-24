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
      $:( icxx"return m_F;"(icxx"return &m_exe_ctx;"); nothing );
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

function initialize_commands(CI)
    dbg = icxx"&$CI.GetDebugger();"
    AddCommand(CI,"jbt") do ctx
      thread = current_thread(ctx)
      for frame in thread
        isJuliaFrame(frame) || continue
        println(STDOUT,getFrameDescription(dbg,icxx"*$ctx;",frame))
        #println(STDOUT,Gallium.dump(frame))
      end
    end
end
