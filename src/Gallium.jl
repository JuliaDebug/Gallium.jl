module Gallium
    using Hooking
    using ASTInterpreter
    using Base.Meta
    using DWARF
    using ObjFileBase
    using ELF
    using MachO
    using AbstractTrees
    import ASTInterpreter: @enter
    export breakpoint, @enter, @breakpoint

    immutable JuliaStackFrame
        oh
        file
        ip
        sstart
        line::Int
        linfo::LambdaInfo
        variables::Dict
        locals::Dict
    end

    immutable CStackFrame
        ip::Ptr{Void}
    end

    # Fake "Interpreter" that is just a native stack
    immutable NativeStack
        stack
    end

    ASTInterpreter.done!(stack::NativeStack) = nothing

    function ASTInterpreter.print_frame(io, num, x::JuliaStackFrame)
        print(io, "[$num] ")
        linfo = x.linfo
        ASTInterpreter.print_linfo_desc(io, linfo)
        argnames = Base.uncompressed_ast(linfo).args[1][2:end]
        ASTInterpreter.print_locals(io, x.locals, (io,name)->begin
            if haskey(x.variables, name)
                if x.variables[name] == 0x0
                    println(io, "<found in DWARF but unavailable>")
                else
                    println(io, "<available>")
                end
            else
                println(io, "<not found in DWARF>")
            end
        end)
    end

    function ASTInterpreter.print_status(x::JuliaStackFrame; kwargs...)
        if x.line < 0
            println("Got a negative line number. Bug?")
        elseif isempty(x.file) || x.line == 0
            println("<No file found. Did DWARF parsing fail?>")
        else
            ASTInterpreter.print_sourcecode(x.linfo, readstring(x.file), x.line)
        end
    end

    function ASTInterpreter.print_status(x::NativeStack; kwargs...)
        ASTInterpreter.print_status(x.stack[end]; kwargs...)
    end

    function ASTInterpreter.get_env_for_eval(x::JuliaStackFrame)
        ASTInterpreter.Environment(copy(x.locals), Dict{Symbol, Any}())
    end
    ASTInterpreter.get_linfo(x::JuliaStackFrame) = x.linfo

    # Use this hook to expose extra functionality
    function ASTInterpreter.unknown_command(x::JuliaStackFrame, command)
        lip = UInt(x.ip)-x.sstart-1
        @osx_only if MachO.readheader(x.oh).filetype != MachO.MH_DSYM
            lip = UInt(ip)-1
        end
        if command == "handle"
            eval(Main,:(h = $(x.oh)))
            error()
        elseif command == "sp"
            dbgs = debugsections(x.oh)
            cu = DWARF.searchcuforip(dbgs, lip)
            sp = DWARF.searchspforip(cu, lip)
            AbstractTrees.print_tree(show, IOContext(STDOUT,:strtab=>StrTab(dbgs.debug_str)), sp)
            return
        elseif command == "cu"
            dbgs = debugsections(x.oh)
            cu = DWARF.searchcuforip(dbgs, lip)
            AbstractTrees.print_tree(show, IOContext(STDOUT,:strtab=>StrTab(dbgs.debug_str)), cu)
            return
        elseif command == "ip"
            println(x.ip)
            return
        elseif command == "sstart"
            println(x.sstart)
            return
        elseif command == "linetabprog" || command == "linetab"
            dbgs = debugsections(x.oh)
            cu = DWARF.findcubyname(dbgs, string(x.linfo.name))
            line_offset = 0
            for at in DWARF.children(cu)
                if DWARF.tag(at) == DWARF.DW_AT_stmt_list
                    line_offset = convert(UInt, at)
                end
            end
            seek(dbgs.debug_line, line_offset)
            linetab = DWARF.LineTableSupport.LineTable(x.oh.io)
            (command == "linetabprog" ? DWARF.LineTableSupport.dump_program :
                DWARF.LineTableSupport.dump_table)(STDOUT, linetab)
        end
    end

    function ASTInterpreter.unknown_command(x::NativeStack, command)
        ASTInterpreter.unknown_command(x.stack[end], command)
    end


    export breakpoint

    # Move this somewhere better
    function ObjFileBase.getSectionLoadAddress(LOI::Dict, sec)
        return LOI[symbol(bytestring(deref(sec).sectname))]
    end

    function search_linetab(linetab, ip)
        local last_entry
        first = true
        for entry in linetab
            if !first
                if entry.address > reinterpret(UInt64,ip)
                    return last_entry
                end
            end
            first = false
            last_entry = entry
        end
        last_entry
    end

    function stackwalk(RC)
        stack = Any[]
        Hooking.rec_backtrace(RC) do cursor
            ip = reinterpret(Ptr{Void},Hooking.get_ip(cursor))
            ipinfo = (ccall(:jl_lookup_code_address, Any, (Ptr{Void}, Cint),
              ip-1, 0))
            fromC = ipinfo[7]
            if fromC
                push!(stack, CStackFrame(Hooking.get_ip(cursor)))
            else
                data = copy(ccall(:jl_get_dobj_data, Any, (Ptr{Void},), ip))
                buf = IOBuffer(data, true, true)
                h = readmeta(buf)
                locals = ASTInterpreter.prepare_locals(ipinfo[6])
                sstart = ccall(:jl_get_section_start, UInt64, (Ptr{Void},), ip-1)
                local variables, line, file
                try
                    lip = UInt(ip)-sstart-1
                    if isa(h, ELF.ELFHandle)
                        if h.file.header.e_type != ELF.ET_DYN
                            ELF.relocate!(buf, h)
                        end
                    else
                        LOI = Dict(:__text => sstart,
                            :__debug_str=>0) #This one really shouldn't be necessary
                        MachO.relocate!(buf, h; LOI=LOI)
                        # TODO: Unify this
                        if MachO.readheader(h).filetype != MachO.MH_DSYM
                            lip = UInt(ip)-1
                        end
                    end
                    dbgs = debugsections(h)
                    cu = DWARF.searchcuforip(dbgs, lip)
                    sp = DWARF.searchspforip(cu, lip)
                    # Process Compilation Unit to get line table
                    line_offset = DWARF.extract_attribute(cu, DWARF.DW_AT_stmt_list)
                    line_offset = isnull(line_offset) ? 0 : convert(UInt, get(line_offset).value)
                    seek(dbgs.debug_line, line_offset)
                    linetab = DWARF.LineTableSupport.LineTable(h.io)
                    entry = search_linetab(linetab, lip)
                    line = entry.line
                    fileentry = linetab.header.file_names[entry.file]
                    if fileentry.dir_idx == 0
                        file = Base.find_source_file(fileentry.name)
                    else
                        file = joinpath(linetab.header.include_directories[fileentry.dir_idx],
                            fileentry.name)
                    end

                    # Process Subprogram to extract local variables
                    strtab = ObjFileBase.load_strtab(dbgs.debug_str)
                    vartypes = Dict{Symbol,Type}()
                    tlinfo = ipinfo[6]
                    for x in Base.uncompressed_ast(tlinfo).args[2][1]
                        vartypes[x[1]] = isa(x[2],Symbol) ? tlinfo.module.(x[2]) : x[2]
                    end
                    fbreg = DWARF.extract_attribute(sp, DWARF.DW_AT_frame_base)
                    # Array is for DWARF 2 support.
                    fbreg = isnull(fbreg) ? -1 :
                        (isa(get(fbreg).value, Array) ? get(fbreg).value[1] : get(fbreg).value.expr[1]) - DWARF.DW_OP_reg0
                    for vardie in (filter(children(sp)) do child
                                tag = DWARF.tag(child)
                                tag == DWARF.DW_TAG_formal_parameter ||
                                tag == DWARF.DW_TAG_variable
                            end)
                        name = DWARF.extract_attribute(vardie,DWARF.DW_AT_name)
                        loc = DWARF.extract_attribute(vardie,DWARF.DW_AT_location)
                        (isnull(name) || isnull(loc)) && continue
                        name = symbol(bytestring(get(name).value,StrTab(dbgs.debug_str)))
                        loc = get(loc)
                        if loc.spec.form == DWARF.DW_FORM_exprloc
                            sm = DWARF.Expressions.StateMachine{typeof(loc.value).parameters[1]}()
                            function getreg(reg)
                                if reg == DWARF.DW_OP_fbreg
                                    (fbreg == -1) && error("fbreg requested but not found")
                                    Hooking.get_reg(cursor, fbreg)
                                else
                                    Hooking.get_reg(cursor, reg)
                                end
                            end
                            getword(addr) = unsafe_load(reinterpret(Ptr{UInt64}, addr))
                            addr_func(x) = x
                            val = DWARF.Expressions.evaluate_simple_location(
                                sm, loc.value.expr, getreg, getword, addr_func, :NativeEndian)
                            if isa(val, DWARF.Expressions.MemoryLocation)
                                !isbits(vartypes[name]) && continue
                                val = unsafe_load(reinterpret(Ptr{vartypes[name]},
                                    val.i))
                            end
                            locals[name] = val
                        end
                    end
                    variables = Dict()
                catch err
                    @show err
                    Base.show_backtrace(STDOUT, catch_backtrace())
                    variables = Dict()
                    line = 0
                    file = ""
                end
                # process SP.variables here
                #h = readmeta(IOBuffer(data))
                push!(stack, JuliaStackFrame(h, file, ip, sstart, line, ipinfo[6], variables, locals))
            end
        end
        reverse!(stack)
    end

    function breakpoint_hit(hook, RC)
        stack = stackwalk(RC)
        stacktop = pop!(stack)
        linfo = stacktop.linfo
        argnames = Base.uncompressed_ast(linfo).args[1][2:end]
        spectypes = map(x->x[2], Base.uncompressed_ast(linfo).args[2][1][2:length(argnames)+1])
        thunk = Expr(:->,Expr(:tuple,argnames...),Expr(:block,
            :(linfo = $linfo),
            :((loctree, code) = ASTInterpreter.reparse_meth(linfo)),
            :(locals = ASTInterpreter.prepare_locals(linfo)),
            :(for (k,v) in zip(linfo.sparam_syms, linfo.sparam_vals)
                locals[k] = v
            end),
            :(merge!(locals,$(Expr(:call,:Dict,
            [:($(quot(x)) => $x) for x in argnames]...)))),
            :(interp = ASTInterpreter.enter(linfo,ASTInterpreter.Environment(
                locals),
                $(collect(filter(x->!isa(x,CStackFrame),stack)));
                    loctree = loctree, code = code)),
            :(ASTInterpreter.RunDebugREPL(interp)),
            :(ASTInterpreter.finish!(interp)),
            :(return interp.retval::$(linfo.rettype))))
        f = eval(thunk)
        faddr = Hooking.get_function_addr(f, Tuple{spectypes...})
        Hooking.Deopt(faddr)
    end

    function breakpoint(addr::Ptr{Void})
        Hooking.hook(breakpoint_hit, addr)
    end

    function breakpoint(func, args)
        Hooking.hook(breakpoint_hit, func, args)
    end

    macro breakpoint(ex0)
        Base.gen_call_with_extracted_types(:(Gallium.breakpoint),ex0)
    end

    # For now this is a very simple implementation. A better implementation
    # would trap and reuse logic. That will become important once we actually
    # support optimized code to avoid cloberring registers. For now do the dead
    # simple, stupid thing.
    function breakpoint()
        RC = Hooking.RegisterContext()
        ccall(:jl_unw_getcontext,Cint,(Ptr{Void},),RC.data)
        ASTInterpreter.RunDebugREPL(NativeStack(filter(x->isa(x,JuliaStackFrame),stackwalk(RC)[1:end-1])))
    end

end
