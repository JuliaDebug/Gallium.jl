using Gallium, Cxx
dbg = debugger()
include(Pkg.dir("Gallium","src","lldbrepl.jl"))
if isdefined(Base,:active_repl)
  RunLLDBRepl(dbg)
  Gallium.createTargetREPL(dbg)
  Gallium.RunTargetREPL(dbg)
  # Step up Target C++ mode
  Cxx.addHeaderDir(Gallium.TargetClang,joinpath(JULIA_HOME,"../../src"))
  Cxx.addHeaderDir(Gallium.TargetClang,joinpath(JULIA_HOME,"../../src/support"))
  Cxx.addHeaderDir(Gallium.TargetClang,joinpath(JULIA_HOME,"../../usr/include"))
  cxxparse(Gallium.TargetClang,"""#include "julia.h" """)
  cxxparse(Gallium.TargetClang,readall(joinpath(dirname(@__FILE__),"../src/boottarget.cpp")))
end
lldb_exec(dbg,"target create $(joinpath(JULIA_HOME,"julia"))")
lldb_exec(dbg,"process attach --pid $(ARGS[1])")
lldb_exec(dbg,"thread select 1")
lldb_exec(dbg,"settings append target.source-map . $(joinpath(JULIA_HOME,"../../base"))")


#=
C = Cxx.instance(Gallium.TargetClang)
rt = Cxx.cpptype(C,Void)
ectx = Gallium.ctx(dbg)
faddr = Gallium.getFunctionCallAddress(dbg,
  Gallium.lookup_function(dbg,"jl_eval_string"))
arguments = ["println(\"Hello World\")"]
Gallium.CreateCallFunctionPlan(C, rt, ectx, faddr, arguments)
=#
