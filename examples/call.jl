using Gallium
dbg = debugger()
include(Pkg.dir("Gallium","src","lldbrepl.jl"))
if isdefined(Base,:active_repl)
  RunLLDBRepl(dbg)
end
lldb_exec(dbg,"target create ~/julia/julia")
lldb_exec(dbg,"process attach --pid $(ARGS[1])")
lldb_exec(dbg,"thread select 1")


#=
C = Cxx.instance(Gallium.TargetClang)
rt = Cxx.cpptype(C,Void)
ectx = Gallium.ctx(dbg)
faddr = Gallium.getFunctionCallAddress(dbg,
  Gallium.lookup_function(dbg,"jl_eval_string"))
arguments = ["println(\"Hello World\")"]
Gallium.CreateCallFunctionPlan(C, rt, ectx, faddr, arguments)
=#
