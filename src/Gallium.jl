include("$(Pkg.dir())/DIDebug/src/DIDebugLite.jl")
module Gallium
    using Hooking
    using ASTInterpreter
    using Base.Meta
    using DWARF
    using ObjFileBase
    using ELF
    using MachO
    using DIDebug
    import ASTInterpreter: @enter
    export breakpoint, @enter

    immutable JuliaStackFrame
        oh
        file
        line::Int
        linfo::LambdaInfo
        variables::Dict
        locals::Dict
    end

    immutable CStackFrame
        ip::Ptr{Void}
    end

    immutable NativeStack
        stack
    end

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
        @show (x.file, x.line)
        ASTInterpreter.print_sourcecode(x.linfo, readstring(x.file), x.line)
    end

    function ASTInterpreter.get_env_for_eval(x::JuliaStackFrame)
        ASTInterpreter.Environment(copy(x.locals), Dict{Symbol, Any}())
    end
    ASTInterpreter.get_linfo(x::JuliaStackFrame) = x.linfo

    # Use this hook to expose extra functionality
    function ASTInterpreter.unknown_command(x::JuliaStackFrame, command)
        if command == "handle"
            eval(Main,:(h = $(x.oh)))
            error()
        elseif command == "sp"
            dbgs = debugsections(x.oh)
            s = DWARF.finddietreebyname(dbgs, string(x.linfo.name))
            println(s)
            return
        elseif command == "cu"
            dbgs = debugsections(x.oh)
            s = DWARF.findcubyname(dbgs, string(x.linfo.name))
            println(s)
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

    function breakpoint_hit(hook, RC)
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
                local variables, line, file
                try
                    if isa(h, ELF.ELFHandle)
                        ELF.relocate!(buf, h)
                    else
                        sstart = ccall(:jl_get_section_start, UInt64, (Ptr{Void},), ip-1)
                        LOI = Dict(:__text => sstart,
                            :__debug_str=>0) #This one really shouldn't be necessary
                        MachO.relocate!(buf, h; LOI=LOI)
                    end
                    dbgs = debugsections(h)
                    cu, sp = DWARF.findcuspbyname(dbgs, string(ipinfo[1]))
                    # Process Compilation Unit to get line table
                    line_offset = 0
                    for at in DWARF.children(cu)
                        if DWARF.tag(at) == DWARF.DW_AT_stmt_list
                            line_offset = convert(UInt, at)
                        end
                    end
                    seek(dbgs.debug_line, line_offset)
                    linetab = DWARF.LineTableSupport.LineTable(h.io)
                    entry = search_linetab(linetab, ip-1)
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
                    SP = DIDebug.process_SP(isa(sp, DWARF.DIETreeRef) ? sp.tree.children[1] : sp, strtab)
                    vartypes = Dict{Symbol,Type}()
                    tlinfo = ipinfo[6]
                    for x in Base.uncompressed_ast(tlinfo).args[2][1]
                        vartypes[x[1]] = isa(x[2],Symbol) ? tlinfo.module.(x[2]) : x[2]
                    end
                    for (k,v) in SP.variables
                        if isa(v, DWARF.Attributes.ExprLocAttribute)
                            opcodes = v.content
                            sm = DWARF.Expressions.StateMachine{UInt64}()
                            function getreg(reg)
                                if reg == DWARF.DW_OP_fbreg
                                    Hooking.get_reg(cursor, SP.fbreg)
                                else
                                    Hooking.get_reg(cursor, reg)
                                end
                            end
                            getword(addr) = unsafe_load(reinterpret(Ptr{UInt64}, addr))
                            addr_func(x) = x
                            val = DWARF.Expressions.evaluate_simple_location(
                                sm, opcodes, getreg, getword, addr_func, :NativeEndian)
                            if isa(val, DWARF.Expressions.MemoryLocation)
                                val = unsafe_load(reinterpret(Ptr{vartypes[k]},
                                    val.i))
                            end
                            locals[k] = val
                        end
                    end
                    variables = SP.variables
                catch err
                    @show err
                    Base.show_backtrace(STDOUT, catch_backtrace())
                    variables = Dict()
                    line = 0
                    file = ""
                end
                # process SP.variables here
                #h = readmeta(IOBuffer(data))
                push!(stack, JuliaStackFrame(h, file, line, ipinfo[6], variables, locals))
            end
        end
        reverse!(stack)
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

end
