function compute_nlines(meth)
    lines = collect(map(x->x.line,
        filter(x->isa(x,LineNumberNode),
        Base.uncompressed_ast(meth.lambda_template))))
    isempty(lines) ? 1 : maximum(lines) - meth.line
end

const filemap = Dict{Symbol, Vector{Method}}()
function register_meth(meth)
    !haskey(filemap, meth.file) && (filemap[meth.file] = Vector{Method}())
    push!(filemap[meth.file], meth)
end
function initial_sweep()
    const visited_modules = Set{Core.Module}()
    const workqueue = Set{Core.Module}()
    push!(workqueue, Main)
    push!(visited_modules, Main)
    while !isempty(workqueue)
        mod = pop!(workqueue)
        for sym in names(mod, true)
            !isdefined(mod, sym) && continue
            Base.isdeprecated(mod, sym) && continue
            x = getfield(mod, sym)
            if isa(x, Core.Module)
                !(x in visited_modules) && push!(workqueue, x)
                push!(visited_modules, x)
                continue
            else
                mt = methods(x)
                for m in mt
                    register_meth(m)
                end
            end
        end
    end
    for (k,v) in filemap
        sort!(v, by = m->m.line)
    end
end

type MethSource <: LocationSource
    bp::Breakpoint
    fT::Type
    meth_predicate
    spec_predicate
    function MethSource(bp::Breakpoint,fT::Type, meth_predicate=meth->true, spec_predicate=spec->true)
        !haskey(TracedTypes, fT) && (TracedTypes[fT] = Set{MethSource}())
        this = new(bp,fT,meth_predicate,spec_predicate)
        push!(TracedTypes[fT], this)
        finalizer(this,function (this)
            pop!(TracedTypes[this.fT], this)
            if isempty(TracedTypes[this.fT])
                delete!(TracedMethods, this.fT)
            end
        end)
        this
    end
end

function Base.show(io::IO, source::MethSource)
    print(io,"Any matching method added to ",source.fT)
end
const TracedTypes = Dict{Type,Set{MethSource}}()

type FileLineSource <: LocationSource
    bp::Breakpoint
    fname::Symbol
    line::Int
    function FileLineSource(bp, fname, line)
        this = new(bp, fname, line)
        push!(FLBPs, this)
        this
    end
end
function Base.show(io::IO, source::FileLineSource)
    print(io,"Any method reaching ",source.fname,":",source.line)
end
const FLBPs = Vector{FileLineSource}()


function fire(s::FileLineSource, meth)
    add_meth_to_bp!(s.bp, meth)
end

function fire(s::MethSource, meth)
    s.meth_predicate(meth) || return
    add_meth_to_bp!(s.bp, meth, s.spec_predicate)
end

function newmeth_tracer(x::Ptr{Void})
    meth = unsafe_pointer_to_objref(x)::Method
    fT = meth.lambda_template.specTypes.parameters[1]
    if haskey(TracedTypes, fT)
        for source in TracedTypes[fT]
            fire(source, meth)
        end
    end
    for source in FLBPs
        contains(string(meth.file), string(source.fname)) || continue
        if meth.line <= source.line <= meth.line + compute_nlines(meth)
            fire(source, meth)
        end
    end
    register_meth(meth)
    nothing
end

global did_arm_breakfile = false
function arm_breakfile()
    did_arm_breakfile && return
    did_arm_breakfile = true
    initial_sweep()
    ccall(:jl_register_newmeth_tracer, Void, (Ptr{Void},), cfunction(newmeth_tracer, Void, (Ptr{Void},)))
end

function methods_for_line(meths, line)
    ret = Vector{Method}()
    for meth in meths
        meth.line > line && break
        if line < meth.line + compute_nlines(meth)
            push!(ret, meth)
        end
    end
    ret
end

function breakpoint(file::AbstractString, line::Int)
    arm_breakfile()
    bp = Breakpoint()
    found = false
    for (fname, meths) in filemap
        contains(string(fname), file) || continue
        found = true
        for meth in methods_for_line(meths, line)
            add_meth_to_bp!(bp, meth)
        end
    end
    if !found
        warn("No file $file found in loaded packages or included files.")
    end
    unshift!(bp.sources, FileLineSource(bp, file, line))
    bp
end
