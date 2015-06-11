using Gallium

function RunLLDBRepl(dbg)
    # Setup cxx panel
    panel = LineEdit.Prompt("LLDB > ";
        # Copy colors from the prompt object
        prompt_prefix=Base.text_colors[:blue],
        prompt_suffix=Base.text_colors[:white],
        on_enter = s->true)

    repl = Base.active_repl

    panel.on_done = REPL.respond(repl,panel) do line
        :( print(lldb_exec($dbg,$line)) )
    end

    main_mode = repl.interface.modes[1]

    push!(repl.interface.modes,panel)

    hp = main_mode.hist
    hp.mode_mapping[:lldb] = panel
    panel.hist = hp

    const lldb_keymap = Dict{Any,Any}(
        '`' => function (s,args...)
            if isempty(s)
                if !haskey(s.mode_state,panel)
                    s.mode_state[panel] = LineEdit.init_state(repl.t,panel)
                end
                LineEdit.transition(s,panel)
            else
                LineEdit.edit_insert(s,'`')
            end
        end
    )

    search_prompt, skeymap = LineEdit.setup_search_keymap(hp)
    mk = REPL.mode_keymap(main_mode)

    b = Dict{Any,Any}[skeymap, mk, LineEdit.history_keymap, LineEdit.default_keymap, LineEdit.escape_defaults]
    panel.keymap_dict = LineEdit.keymap(b)

    main_mode.keymap_dict = LineEdit.keymap_merge(main_mode.keymap_dict, lldb_keymap);
    nothing
end
