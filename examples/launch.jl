OLDARGS = copy(ARGS)
atreplinit() do args...
  append!(ARGS,OLDARGS)
  repl = Base.active_repl
  println(STDOUT,"="^Base.Terminals.width(Base.active_repl.t))
  println(STDOUT," "^(div(Base.Terminals.width(Base.active_repl.t),2)-12),"Launching Gallium")
  println(STDOUT,"="^Base.Terminals.width(Base.active_repl.t))
  if (isdefined(repl,:mi) && !isdefined(repl.mi,:interface))
    repl.mi.interface = Base.REPL.setup_interface(repl)
  elseif !isdefined(repl,:interface)
    repl.interface = Base.REPL.setup_interface(repl)
  end
  include("call.jl")
  empty!(Core.ARGS)
end
empty!(Core.ARGS)
Base._start()
exit()
