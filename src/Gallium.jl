__precompile__()
module Gallium
    using ASTInterpreter
    using Base.Meta
    using DWARF
    using ObjFileBase
    using ELF
    using MachO
    using AbstractTrees
    import ASTInterpreter: @enter

    # Debugger User Interface
    export breakpoint, @enter, @breakpoint, @conditional

    include("remote.jl")
    include("registers.jl")
    include("x86_64/registers.jl")
    include("modules.jl")
    include("unwind.jl")
    include("Hooking/Hooking.jl")

    using .Registers
    using .Registers: ip, get_dwarf
    using .Hooking

    type JuliaStackFrame
        oh
        file
        ip
        sstart
        line::Int
        linfo::LambdaInfo
        variables::Dict
        env::Environment
    end

    type CStackFrame
        ip::Ptr{Void}
        file::AbstractString
        line::Int
        stacktop::Bool
    end

    # Fake "Interpreter" that is just a native stack
    immutable NativeStack
        stack
        modules
    end

    ASTInterpreter.done!(stack::NativeStack) = nothing

    function ASTInterpreter.print_frame(io, num, x::JuliaStackFrame)
        print(io, "[$num] ")
        linfo = x.linfo
        ASTInterpreter.print_linfo_desc(io, linfo)
        println(io)
        ASTInterpreter.print_locals(io, linfo, x.env, (io,name)->begin
            if haskey(x.variables, name)
                if x.variables[name] == :available
                    println(io, "<undefined>")
                else
                    println(io, "<not available here>")
                end
            else
                println(io, "<optimized out>")
            end
        end)
    end
    ASTInterpreter.print_frame(io, num, x::NativeStack) =
        ASTInterpreter.print_frame(io, num, x.stack[end])

    function ASTInterpreter.print_status(x::JuliaStackFrame; kwargs...)
        if x.line < 0
            println("Got a negative line number. Bug?")
        elseif (!isa(x.file,AbstractString) || isempty(x.file)) || x.line == 0
            println("<No file found. Did DWARF parsing fail?>")
        else
            ASTInterpreter.print_sourcecode(x.linfo, readstring(x.file), x.line)
        end
    end

    function ASTInterpreter.print_status(x::NativeStack; kwargs...)
        ASTInterpreter.print_status(x.stack[end]; kwargs...)
    end

    function ASTInterpreter.get_env_for_eval(x::JuliaStackFrame)
        copy(x.env)
    end
    ASTInterpreter.get_env_for_eval(x::NativeStack) =
        ASTInterpreter.get_env_for_eval(x.stack[end])
    ASTInterpreter.get_linfo(x::JuliaStackFrame) = x.linfo
    ASTInterpreter.get_linfo(x::NativeStack) =
        ASTInterpreter.get_linfo(x.stack[end])

    const GalliumFrame = Union{NativeStack, JuliaStackFrame, CStackFrame}
    using DWARF: CallFrameInfo
    function ASTInterpreter.execute_command(state, x::GalliumFrame, ::Val{:cfi}, command)
        modules = state.top_interp.modules
        ip = isa(x, NativeStack) ? x.stack[end].ip : x.ip
        base, mod = find_module(modules, ip)
        modrel = UInt(ip - base)
        loc, fde = Unwinder.find_fde(mod, modrel)
        cie = realize_cie(fde)
        target_delta = modrel - loc - 1
        out = IOContext(STDOUT, :reg_map => Gallium.X86_64.dwarf_numbering)
        drs = CallFrameInfo.RegStates()
        CallFrameInfo.dump_program(out, cie, target = UInt(target_delta), rs = drs); println(out)
        CallFrameInfo.dump_program(out, fde, cie = cie, target = UInt(target_delta), rs = drs)
        return false
    end

    # Use this hook to expose extra functionality
    function ASTInterpreter.execute_command(x::JuliaStackFrame, command)
        lip = UInt(x.ip)-x.sstart-1
        if isrelocatable(handle(x.oh))
            lip = UInt(x.ip)-1
        end
        if command == "handle"
            eval(Main,:(h = $(x.oh)))
            error()
        elseif command == "sp"
            dbgs = debugsections(dhandle(x.oh))
            cu = DWARF.searchcuforip(dbgs, lip)
            sp = DWARF.searchspforip(cu, lip)
            AbstractTrees.print_tree(show, IOContext(STDOUT,:strtab=>StrTab(dbgs.debug_str)), sp)
            return
        elseif command == "cu"
            dbgs = debugsections(dhandle(x.oh))
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
            dbgs = debugsections(dhandle(x.oh))
            cu = DWARF.searchcuforip(dbgs, lip)
            line_offset = get(DWARF.extract_attribute(cu, DWARF.DW_AT_stmt_list))
            seek(dbgs.debug_line, UInt(line_offset.value))
            linetab = DWARF.LineTableSupport.LineTable(handle(dbgs).io)
            (command == "linetabprog" ? DWARF.LineTableSupport.dump_program :
                DWARF.LineTableSupport.dump_table)(STDOUT, linetab)
        elseif startswith(command, "bp")
            subcmds = split(command,' ')[2:end]
            if subcmds[1] == "list"
                list_breakpoints()
            elseif subcmds[1] == "disable"
                bp = breakpoints[parse(Int,subcmds[2])]
                disable(bp)
                println(bp)
            elseif subcmds[1] == "enable"
                bp = breakpoints[parse(Int,subcmds[2])]
                enable(bp)
                println(bp)
            end
        elseif startswith(command, "b")
            nothing
        end
    end

    function ASTInterpreter.execute_command(x::NativeStack, command)
        ASTInterpreter.execute_command(x.stack[end], command)
    end


    export breakpoint

    # Move this somewhere better
    function ObjFileBase.getSectionLoadAddress(LOI::Dict, sec)
        return LOI[symbol(sectionname(sec))]
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

    function rec_backtrace(RC)
        ips = Array(UInt64, 0)
        rec_backtrace(RC->push!(ips,ip(RC)), RC)
        ips
    end

    global active_modules = LazyLocalModules()
    function rec_backtrace(callback, RC, session = LocalSession(), modules = active_modules)
        callback(RC)
        stacktop = true
        while true
            (ok, RC) = Unwinder.unwind_step(session, modules, RC; stacktop = stacktop)
            stacktop = false
            ok || break
            callback(RC)
        end
    end

    function step_first!(RC)
        set_ip!(RC,unsafe_load(convert(Ptr{UInt},RC.rsp[])))
        set_sp!(RC,RC.rsp[]+sizeof(Ptr{Void}))
    end

    function rec_backtrace_hook(callback, RC, session = LocalSession(), modules = active_modules)
        callback(RC)
        step_first!(RC)
        rec_backtrace(callback, RC, session, modules)
    end

    # Validate that an address is a valid location in the julia heap
    function heap_validate(ptr)
        typeptr = Ptr{Ptr{Void}}(ptr-sizeof(Ptr))
        Hooking.mem_validate(typeptr,sizeof(Ptr)) || return false
        T = UInt(unsafe_load(typeptr))&(~UInt(0x3))
        typetypeptr = Ptr{Ptr{Void}}(T-sizeof(Ptr))
        Hooking.mem_validate(typetypeptr,sizeof(Ptr)) || return false
        UInt(unsafe_load(typetypeptr))&(~UInt(0x3)) == UInt(pointer_from_objref(DataType))
    end

    function stackwalk(RC, session = LocalSession(), modules = active_modules; fromhook = false, rich_c = false)
        stack = Any[]
        firstframe = true
        (fromhook ? rec_backtrace_hook : rec_backtrace)(RC, session, modules) do RC
            theip = reinterpret(Ptr{Void},UInt(ip(RC)))
            ipinfo = (ccall(:jl_lookup_code_address, Any, (Ptr{Void}, Cint),
              theip-1, 0))
            fromC = ipinfo[7]
            file = ""
            line = 0
            if fromC
                (sstart, h) = find_module(modules, theip)
                if rich_c
                    lip = UInt(theip)-sstart-1
                    dh = dhandle(h)
                    dbgs,cu,sp = try
                        (debugsections(dh),
                            DWARF.searchcuforip(dbgs, lip),
                            DWARF.searchspforip(cu, lip))
                    catch
                        (nothing, nothing, nothing)
                    end
                    if dbgs !== nothing
                        # Process Compilation Unit to get line table
                        line_offset = DWARF.extract_attribute(cu, DWARF.DW_AT_stmt_list)
                        line_offset = isnull(line_offset) ? 0 : convert(UInt, get(line_offset).value)

                        seek(dbgs.debug_line, line_offset)
                        linetab = DWARF.LineTableSupport.LineTable(handle(dbgs).io)
                        entry = search_linetab(linetab, lip)
                        line = entry.line
                        fileentry = linetab.header.file_names[entry.file]
                        file = fileentry.name
                    end
                end
                push!(stack, CStackFrame(theip, file, line, firstframe))
            else
                (sstart, h) = find_module(modules, theip)
                ipinfo[6] == nothing && return
                tlinfo = ipinfo[6]::LambdaInfo
                env = ASTInterpreter.prepare_locals(tlinfo)
                copy!(env.sparams, tlinfo.sparam_vals)
                variables = Dict()
                dbgs = debugsections(dhandle(h))
                try
                    lip = UInt(theip)-sstart-1
                    if isrelocatable(handle(h))
                        lip = UInt(theip)-1
                    end
                    cu = DWARF.searchcuforip(dbgs, lip)
                    sp = DWARF.searchspforip(cu, lip)
                    # Process Compilation Unit to get line table
                    line_offset = DWARF.extract_attribute(cu, DWARF.DW_AT_stmt_list)
                    line_offset = isnull(line_offset) ? 0 : convert(UInt, get(line_offset).value)

                    seek(dbgs.debug_line, line_offset)
                    linetab = DWARF.LineTableSupport.LineTable(handle(dbgs).io)
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
                    if tlinfo.slottypes === nothing
                        for name in tlinfo.slotnames
                            vartypes[name] = Any
                        end
                    else
                        for (name, ty) in zip(tlinfo.slotnames, tlinfo.slottypes)
                            vartypes[name] = ty
                        end
                    end
                    fbreg = DWARF.extract_attribute(sp, DWARF.DW_AT_frame_base)
                    # Array is for DWARF 2 support.
                    fbreg = isnull(fbreg) ? -1 :
                        (isa(get(fbreg).value, Array) ? get(fbreg).value[1] : get(fbreg).value.expr[1]) - DWARF.DW_OP_reg0
                    variables = Dict()
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
                                    get_dwarf(RC, fbreg)
                                else
                                    get_dwarf(RC, reg)
                                end
                            end
                            getword(addr) = unsafe_load(reinterpret(Ptr{UInt64}, addr))
                            addr_func(x) = x
                            val = DWARF.Expressions.evaluate_simple_location(
                                sm, loc.value.expr, getreg, getword, addr_func, :NativeEndian)
                            variables[name] = :found
                            if isa(val, DWARF.Expressions.MemoryLocation)
                                if isbits(vartypes[name])
                                    val = unsafe_load(reinterpret(Ptr{vartypes[name]},
                                        val.i))
                                else
                                    ptr = reinterpret(Ptr{Void}, val.i)
                                    if ptr == C_NULL
                                        val = Nullable{Ptr{vartypes[name]}}()
                                    elseif heap_validate(ptr)
                                        val = unsafe_pointer_to_objref(ptr)
                                    # This is a heuristic. Should update to check
                                    # whether the variable is declared as jl_value_t
                                    elseif Hooking.mem_validate(ptr, sizeof(Ptr{Void}))
                                        ptr2 = unsafe_load(Ptr{Ptr{Void}}(ptr))
                                        if ptr2 == C_NULL
                                            val = Nullable{Ptr{vartypes[name]}}()
                                        elseif heap_validate(ptr2)
                                            val = unsafe_pointer_to_objref(ptr2)
                                        end
                                    end
                                end
                                variables[name] = :available
                            elseif isa(val, DWARF.Expressions.RegisterLocation)
                                # The value will generally be in the low bits of the
                                # register. This should give the appropriate value
                                val = reinterpret(vartypes[name],[getreg(val.i)])[]
                                variables[name] = :available
                            end
                            varidx = findfirst(tlinfo.slotnames, name)
                            if varidx != 0
                                env.locals[varidx] = Nullable{Any}(val)
                            end
                        end
                    end
                catch err
                    @show err
                    Base.show_backtrace(STDOUT, catch_backtrace())
                end
                # process SP.variables here
                #h = readmeta(IOBuffer(data))
                push!(stack, JuliaStackFrame(h, file, UInt(ip(RC)), sstart, line, ipinfo[6], variables, env))
            end
            firstframe = false
        end
        reverse!(stack)
    end

    function matches_condition(interp, condition)
        condition == nothing && return true
        if isa(condition, Expr)
            ok, res = ASTInterpreter.eval_in_interp(interp, condition)
            !ok && println("Conditional breakpoint errored. Breaking.")
            return !ok || res
        else
            error("Unexpected condition kind")
        end
    end

    macro conditional(bp, condition)
        esc(:(let bp = $bp
            bp.condition = $(Expr(:quote, condition))
            bp
        end))
    end

    function breakpoint_hit(hook, RC)
        stack = stackwalk(RC; fromhook = true)
        stacktop = pop!(stack)
        linfo = stacktop.linfo
        argnames = linfo.slotnames[2:linfo.nargs]
        spectypes = linfo.specTypes.parameters[2:end]
        bps = bps_at_location[Location(LocalSession(),hook.addr)]
        target_line = minimum(map(bps) do bp
            idx = findfirst(s->isa(s, FileLineSource), bp.sources)
            idx != 0 ? bp.sources[idx].line : linfo.def.line
        end)
        conditions = map(bp->bp.condition, bps)
        thunk = Expr(:->,Expr(:tuple,argnames...),Expr(:block,
            :(linfo = $(quot(linfo))),
            :((loctree, code) = ASTInterpreter.reparse_meth(linfo)),
            :(__env = ASTInterpreter.prepare_locals(linfo.def.lambda_template)),
            :(copy!(__env.sparams, linfo.sparam_vals)),
            :(__env.locals[1] = Nullable{Any}()),
            [ :(__env.locals[$i + 1] = Nullable{Any}($(argnames[i]))) for i = 1:length(argnames) ]...,
            :(interp = ASTInterpreter.enter(linfo,__env,
                $(collect(filter(x->!isa(x,CStackFrame),stack)));
                    loctree = loctree, code = code)),
            (target_line != linfo.def.line ?
                :(ASTInterpreter.advance_to_line(interp, $target_line)) :
                :(nothing)),
            :(any(c->Gallium.matches_condition(interp,c),$conditions) &&
                ASTInterpreter.RunDebugREPL(interp)),
            :(ASTInterpreter.finish!(interp)),
            :(return interp.retval::$(linfo.rettype))))
        f = eval(thunk)
        faddr = Hooking.get_function_addr(f, Tuple{spectypes...})
        Hooking.Deopt(faddr)
    end
    abstract LocationSource
    immutable Location
        vm
        addr::UInt64
    end
    type Breakpoint
        active_locations::Vector{Location}
        inactive_locations::Vector{Location}
        sources::Vector{LocationSource}
        disable_new::Bool
        condition::Any
    end
    Breakpoint(locations::Vector{Location}) = Breakpoint(locations, Location[], LocationSource[], false, nothing)
    Breakpoint() = Breakpoint(Location[], Location[], LocationSource[], false, nothing)

    function print_locations(io::IO, locations, prefix = " - ")
        for loc in locations
            print(io,prefix)
            ipinfo = (ccall(:jl_lookup_code_address, Any, (UInt, Cint),
                loc.addr, 0))
            fromC = ipinfo[7]
            if fromC
                println(io, "At address ", addr)
            else
                linfo = ipinfo[6]::LambdaInfo
                ASTInterpreter.print_linfo_desc(io, linfo, true)
                println(io)
            end
        end
    end

    function Base.show(io::IO, b::Breakpoint)
        if isempty(b.active_locations) && isempty(b.inactive_locations) &&
            isempty(b.sources)
            println(io, "Empty Breakpoint")
            return
        end
        println(io, "Locations (+: active, -: inactive, *: source):")
        !isempty(b.active_locations) && print_locations(io, b.active_locations, " + ")
        !isempty(b.inactive_locations) && print_locations(io, b.inactive_locations, " - ")
        for source in b.sources
            print(io," * ")
            println(io,source)
        end
    end

    const bps_at_location = Dict{Location, Set{Breakpoint}}()
    function disable(bp::Breakpoint, loc::Location)
        pop!(bps_at_location[loc],bp)
        if isempty(bps_at_location[loc])
            unhook(Ptr{Void}(loc.addr))
            delete!(bps_at_location,loc)
        end
    end
    function disable(b::Breakpoint)
        locs = copy(b.active_locations)
        empty!(b.active_locations)
        for loc in locs
            disable(b, loc)
            push!(b.inactive_locations, loc)
        end
        b.disable_new = true
    end
    remove(b::Breakpoint) = (disable(b); deleteat!(breakpoints, findfirst(breakpoints, b)); nothing)

    function enable(bp::Breakpoint, loc::Location)
        if !haskey(bps_at_location, loc)
            hook(breakpoint_hit, Ptr{Void}(loc.addr))
            bps_at_location[loc] = Set{Breakpoint}()
        end
        push!(bps_at_location[loc], bp)
    end
    function enable(b::Breakpoint)
        locs = copy(b.inactive_locations)
        empty!(b.inactive_locations)
        for loc in locs
            enable(b, loc)
            push!(b.active_locations, loc)
        end
        b.disable_new = false
    end

    function _breakpoint_spec(spec::LambdaInfo, bp)
        llvmf = ccall(:jl_get_llvmf, Ptr{Void}, (Any, Bool, Bool), spec.specTypes, false, true)
        @assert llvmf != C_NULL
        fptr = ccall(:jl_get_llvm_fptr, UInt64, (Ptr{Void},), llvmf)
        @assert fptr != 0
        loc = Location(LocalSession(), fptr)
        add_location(bp, loc)
    end

    function _breakpoint_method(meth::Method, bp::Breakpoint, predicate = linfo->true)
        isdefined(meth, :specializations) || return
        for spec in meth.specializations
            predicate(spec) || continue
            _breakpoint_spec(spec, bp)
        end
    end

    type SpecSource <: LocationSource
        bp::Breakpoint
        meth::Method
        predicate
        function SpecSource(bp::Breakpoint, meth::Method, predicate)
            !haskey(TracedMethods, meth) && (TracedMethods[meth] = Set{SpecSource}())
            ccall(:jl_trace_method, Void, (Any,), meth)
            this = new(bp, meth, predicate)
            push!(TracedMethods[meth], this)
            finalizer(this,function (this)
                pop!(TracedMethods[this.meth], this)
                if isempty(TracedMethods[this.meth])
                    ccall(:jl_untrace_method, Void, (Any,), this.meth)
                    delete!(TracedMethods, this.meth)
                end
            end)
            this
        end
    end
    function fire(s::SpecSource, linfo::LambdaInfo)
        s.predicate(linfo) || return
        _breakpoint_spec(linfo, s.bp)
    end

    const TracedMethods = Dict{Method, Set{SpecSource}}()
    function Base.show(io::IO, source::SpecSource)
        print(io,"Any matching specialization of ")
        ASTInterpreter.print_linfo_desc(io, source.meth.lambda_template, true)
    end

    function rebreak_tracer(x::Ptr{Void})
        linfo = unsafe_pointer_to_objref(x)::LambdaInfo
        !haskey(TracedMethods, linfo.def) && return nothing
        for s in TracedMethods[linfo.def]
            fire(s, linfo)
        end
        nothing
    end

    function add_meth_to_bp!(bp::Breakpoint, meth::Union{Method, TypeMapEntry}, predicate = linfo->true)
        isa(meth, TypeMapEntry) && (meth = meth.func)
        _breakpoint_method(meth, bp, predicate)
        push!(bp.sources, SpecSource(bp, meth, predicate))
        bp
    end

    function breakpoint(meth::Union{Method, TypeMapEntry})
        bp = add_meth_to_bp!(Breakpoint(), meth)
        push!(breakpoints, bp)
        bp
     end

    const breakpoints = Vector{Breakpoint}()

    function list_breakpoints()
        for (i, bp) in enumerate(breakpoints)
            println("[$i] $bp")
        end
    end

    function breakpoint(addr::Ptr{Void})
        hook(breakpoint_hit, addr)
    end

    function add_location(bp, loc)
        if bp.disable_new
            push!(bp.inactive_locations, loc)
        else
            push!(bp.active_locations, loc)
            enable(bp, loc)
        end
    end

    function _breakpoint_concrete(bp, t)
        addr = Hooking.get_function_addr(t)
        add_location(bp, Location(LocalSession(),addr))
    end

    function breakpoint(func, args)
        argtt = Base.to_tuple_type(args)
        t = Tuple{typeof(func), argtt.parameters...}
        bp = Breakpoint()
        if Base.isleaftype(t)
            _breakpoint_concrete(bp, t)
        else
            spec_predicate(linfo) = linfo.specTypes <: t
            meth_predicate(meth) = t <: meth.lambda_template.specTypes || meth.lambda_template.specTypes <: t
            for meth in methods(func, argtt)
                add_meth_to_bp!(bp, meth, spec_predicate)
            end
            push!(bp.sources, MethSource(bp, typeof(func), meth_predicate, spec_predicate))
        end
        push!(breakpoints, bp)
        bp
    end

    include("breakfile.jl")

    function method_tracer(x::Ptr{Void})
        ccall(:jl_trace_linfo, Void, (Ptr{Void},), x)
        nothing
    end

    function __init__()
        ccall(:jl_register_linfo_tracer, Void, (Ptr{Void},), cfunction(rebreak_tracer,Void,(Ptr{Void},)))
        ccall(:jl_register_method_tracer, Void, (Ptr{Void},), cfunction(method_tracer,Void,(Ptr{Void},)))
        arm_breakfile()
        update_shlibs!(active_modules)
    end

    function breakpoint(f)
        bp = Breakpoint()
        Base.visit(methods(f)) do meth
            add_meth_to_bp!(bp, meth)
        end
        unshift!(bp.sources, MethSource(bp, typeof(f)))
        push!(breakpoints, bp)
        bp
    end

    macro breakpoint(ex0)
        Base.gen_call_with_extracted_types(:(Gallium.breakpoint),ex0)
    end

    # For now this is a very simple implementation. A better implementation
    # would trap and reuse logic. That will become important once we actually
    # support optimized code to avoid cloberring registers. For now do the dead
    # simple, stupid thing.
    function breakpoint()
        RC = Hooking.getcontext()
        # -2 to skip getcontext and breakpoint()
        ASTInterpreter.RunDebugREPL(NativeStack(filter(x->isa(x,JuliaStackFrame),stackwalk(RC; fromhook = true)[1:end-2],active_modules)))
    end

    function breakpoint_on_error_hit(thehook, RC)
        unhook(thehook)
        err = unsafe_pointer_to_objref(Ptr{Void}(RC.rdi[]))
        stack = stackwalk(RC; fromhook = true)
        ips = [x.ip-1 for x in stack]
        Base.with_output_color(:red, STDERR) do io
            print(io, "ERROR: ")
            Base.showerror(io, err, reverse(ips); backtrace=false)
            println(io)
        end
        println(STDOUT)
        ASTInterpreter.RunDebugREPL(NativeStack(filter(x->isa(x,JuliaStackFrame),stack),active_modules))
        # Get a somewhat sensible backtrace when returning
        try; throw(); catch; end
        hook(thehook)
        rethrow(err)
    end

    # Compiling these function has an error thrown/caught in type inference.
    # Precompile them here, to make sure we make it throught
    precompile(breakpoint_on_error_hit,(Hooking.Hook,X86_64.BasicRegs))
    precompile(Hooking.callback,(Ptr{Void},))

    function breakpoint_on_error(enable = true)
        addr = cglobal(:jl_throw)
        if enable
            hook(breakpoint_on_error_hit, addr)
        else
            unhook(addr)
        end
    end

    include("precompile.jl")
end
