include("$(Pkg.dir())/DIDebug/src/DIDebugLite.jl")
module Gallium
    using Hooking
    using ASTInterpreter
    using Base.Meta
    using DWARF
    using ObjFileBase
    using ELF
    using DIDebug

    immutable JuliaStackFrame
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
        println("<Source information not yet available for native frames>")
    end

    function ASTInterpreter.get_env_for_eval(x::JuliaStackFrame)
        ASTInterpreter.Environment(copy(x.locals), Dict{Symbol, Any}())
    end
    ASTInterpreter.get_linfo(x::JuliaStackFrame) = x.linfo

    ASTInterpreter._evaluated!(x::NativeStack, y) = nothing

    export breakpoint

    function breakpoint_hit(hook, RC)
        stack = Any[]
        Hooking.rec_backtrace(RC) do cursor
            ip = reinterpret(Ptr{Void},Hooking.get_ip(cursor))
            ipinfo = (ccall(:jl_lookup_code_address, Any, (Ptr{Void}, Cint),
              ip-1, 0))
            @show ipinfo
            fromC = ipinfo[7]
            if fromC
                push!(stack, CStackFrame(Hooking.get_ip(cursor)))
            else
                data = copy(ccall(:jl_get_dobj_data, Any, (Ptr{Void},), ip))
                buf = IOBuffer(data, true, true)
                h = readmeta(buf)
                ELF.relocate!(buf, h)
                dbgs = debugsections(h)
                @show ipinfo[1]
                s = DWARF.finddietreebyname(dbgs, string(ipinfo[1]))
                @show s
                SP = DIDebug.process_SP(s.tree.children[1], s.strtab)
                @show SP
                locals = ASTInterpreter.prepare_locals(ipinfo[6])
                @show ipinfo[6]
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
                # process SP.variables here
                #h = readmeta(IOBuffer(data))
                push!(stack, JuliaStackFrame(ipinfo[6], SP.variables, locals))
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
            :(interp = ASTInterpreter.enter(linfo,ASTInterpreter.Environment(
                $(Expr(:call,:Dict,
                [:($(quot(x)) => $x) for x in argnames]...)),
                Dict{Symbol,Any}()),
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
