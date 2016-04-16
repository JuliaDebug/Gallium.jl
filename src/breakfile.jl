function compute_nlines(meth)
    maximum(map(x->x.line,
        filter(x->isa(x,LineNumberNode),
        Base.uncompressed_ast(meth.lambda_template))))-meth.line
end

const filemap = Dict{Symbol, Vector{Method}}()
function initial_sweep()
    const visited_modules = Set{Core.Module}()
    const workqueue = Set{Core.Module}()
    push!(workqueue, Main)
    push!(visited_modules, Main)
    while !isempty(workqueue)
        mod = pop!(workqueue)
        for sym in names(mod, true)
            !isdefined(mod, sym) && continue
            x = getfield(mod, sym)
            if isa(x, Core.Module)
                !(x in visited_modules) && push!(workqueue, x)
                push!(visited_modules, x)
                continue
            else
                mts = methods(x)
                !isa(mts, Array) && (mts = [mts])
                for mt in mts
                    Base.visit(mt) do m
                        m = m.func
                        !haskey(filemap, m.file) && (filemap[m.file] = Vector{Method}())
                        push!(filemap[m.file], m)
                    end
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
    function MethSource(bp::Breakpoint,fT::Type)
        !haskey(TracedTypes, fT) && (TracedTypes[fT] = Set{MethSource}())
        this = new(bp,fT)
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
    print(io,"Any method added to ",source.fT)
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


function fire(s::Union{MethSource,FileLineSource}, meth)
    add_meth_to_bp!(s.bp, meth)
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
end

function arm_breakfile()
    initial_sweep()
    ccall(:jl_register_newmeth_tracer, Void, (Ptr{Void},), cfunction(newmeth_tracer, Void, (Ptr{Void},)))
end

function linfos_for_line(linfos, line)
    ret = Vector{LambdaInfo}()
    for linfo in linfos
        linfo.line > line && break
        @show (linfo.line, compute_nlines(linfo))
        if line < linfo.line + compute_nlines(linfo)
            push!(ret, linfo)
        end
    end
    ret
end

function breakpoint(file::AbstractString, line::Int)
    bp = Breakpoint()
    for (fname, linfos) in filemap
        contains(string(fname), file) || continue
        for linfo in linfos_for_line(linfos, line)
            add_meth_to_bp!(bp, linfo)
        end
    end
    unshift!(bp.sources, FileLineSource(bp, file, line))
    bp
end
