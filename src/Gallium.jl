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
        locals::Dict
    end
    
    immutable CStackFrame
        ip::Ptr{Void}
    end

    immutable NativeStack
        stack
    end

    function ASTInterpreter.print_backtrace(x::JuliaStackFrame)
        linfo = x.linfo
        ASTInterpreter.print_linfo_desc(STDOUT, linfo)
        argnames = Base.uncompressed_ast(linfo).args[1][2:end]
        for name in argnames
            print("- ",name," = ")
            if haskey(x.locals, name)
                if x.locals[name] == 0x0
                    println("<found in DWARF but unavailable>")
                else
                    println("<available>")
                end
            else
                println("<not found in DWARF>")
            end
        end
    end

    function ASTInterpreter.print_backtrace(x::NativeStack)
        for s in reverse(x.stack)
            isa(s, JuliaStackFrame) && ASTInterpreter.print_backtrace(s)
        end
    end

    ASTInterpreter._evaluated!(x::NativeStack, y) = nothing

    export breakpoint

    function breakpoint_hit(hook, RC)
        stack = Any[]
        Hooking.rec_backtrace(RC) do cursor
            ip = reinterpret(Ptr{Void},Hooking.get_ip(cursor))
            ipinfo = (ccall(:jl_lookup_code_address, Any, (Ptr{Void}, Cint),
              ip, 0))
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
                #h = readmeta(IOBuffer(data))
                push!(stack, JuliaStackFrame(ipinfo[6], SP.variables))
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
                NativeStack($stack); loctree = loctree, code = code)),
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
