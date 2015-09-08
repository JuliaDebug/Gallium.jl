import Base: LineEdit, REPL

function createTargetREPL(dbg)

  mirepl = isdefined(Base.active_repl,:mi) ? Base.active_repl.mi : Base.active_repl
  repl = Base.active_repl
  main_mode = mirepl.interface.modes[1]
  panel = LineEdit.Prompt("julia> ";
    # Copy colors from the prompt object
    prompt_prefix = "\033[0m\033[32m",
    prompt_suffix = Base.input_color,
    keymap_func_data = mirepl,
    complete = main_mode.complete,
    on_enter = REPL.return_callback)

  push!(mirepl.interface.modes,panel)

  panel.on_done = REPL.respond(repl,panel) do line
    quote
      Gallium.target_call(dbg,:jl_eval_string,[string($line,'\0')])
    end
  end

  const target = Dict{Any,Any}(
       '\\' => function (s,args...)
           if isempty(s) || position(LineEdit.buffer(s)) == 0
               buf = copy(LineEdit.buffer(s))
               LineEdit.transition(s, panel) do
                   LineEdit.state(s, panel).input_buffer = buf
               end
           else
               LineEdit.edit_insert(s,'\\')
           end
       end
   )

   hp = main_mode.hist
   hp.mode_mapping[:targetjulia] = panel
   panel.hist = hp

   search_prompt, skeymap = LineEdit.setup_search_keymap(hp)
   mk = REPL.mode_keymap(main_mode)

   b = Dict{Any,Any}[skeymap, mk, LineEdit.history_keymap,
    LineEdit.default_keymap, LineEdit.escape_defaults]
   panel.keymap_dict = LineEdit.keymap(b)

   main_mode.keymap_dict = LineEdit.keymap_merge(main_mode.keymap_dict, target);

end

function entrypoint_for_julia_expression(target,names, expression)
new_expr = """
cfunction((@eval function (\$(gensym()))($(join(names,",")))\n
    $(join([string(n," = unsafe_pointer_to_objref(",n,")") for n in names],'\n'))
    $expression
  end),
  Any,Tuple{$(join(["Ptr{Void}" for i = 1:length(names)]))})
"""
ptr = Gallium.target_call(target,:jl_eval_string,[string(new_expr,'\0')])
ptr = Gallium.target_call(target,:jl_unbox_voidpointer,[ptr])
end

function call_prepared_entrypoint(target, ectx, entrypoint, args::Vector{Ptr{Void}})
    C = Cxx.instance(Gallium.TargetClang)
    RT = Cxx.cpptype(C,pcpp"_jl_value_t")
    Gallium.CreateCallFunctionPlan(C, RT, ectx, convert(UInt64,entrypoint),
      args)
end
