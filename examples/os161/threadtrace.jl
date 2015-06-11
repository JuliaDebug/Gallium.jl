include("common.jl")

function getThreads(dbg)
    vo = run_expr(dbg,"kproc->p_threads.arr.num")
    num = ValueObjectToJulia(vo)
    threads = Array(Uint32,num)
    for i = 0:num-1
        threads[i+1] = ValueObjectToJulia(run_expr(dbg,"(uint32_t)kproc->p_threads.arr.v[$i]"))
    end
    threads
end

immutable Thread
    name
end

all_threads = Thread[]
active_threads = Dict{Uint32,Any}()
blocked_threads = Dict{Uint32,Int}()
block_events = Array((Int,Int,Int),0)

function thread_get_name(thread)
    return "no name"
end

# Record process creations
function f1(env, ctx, id, loc)
    ctx = pcpp"lldb_private::StoppointCallbackContext"(ctx)
    exe_ctx = @cxx &ctx->exe_ctx_ref
    try
        proc = run_expr(dbg,"(uint32_t)proc",exe_ctx)
        thread = run_expr(dbg,"(uint32_t)t",exe_ctx)
        if haskey(active_threads, thread)
            # Got back to the same place 
            # (can happen if an exception happens at inconvenient places)
            return false
        end
        println("Adding new thread $thread to $proc")
        push!(all_threads, Thread(thread_get_name(thread)))
        id = length(all_threads)
        active_threads[thread] = id
    catch e
        println(e)
        return true
    end
    return false
end
SetBreakpoint(f1,target,"proc_addthread")


# Record process destruction
function f2(env, ctx, id, loc)
    ctx = pcpp"lldb_private::StoppointCallbackContext"(ctx)
    try
        thread = run_expr(dbg,"(uint32_t)t",@cxx &ctx->exe_ctx_ref)
        println("Removing thread $thread")
        @assert haskey(active_threads, thread)
        delete!(active_threads, thread)
    catch e
        println(e)
        return true
    end
    return false
end
SetBreakpoint(f2,target,"proc_remthread")

events = Array((Int,Int),0)

const S_RUN     = 0
const S_READY   = 1
const S_SLEEP   = 2
const S_ZOMBIE  = 3

function f3(env, ctx, id, loc)
    ctx = pcpp"lldb_private::StoppointCallbackContext"(ctx)
    exe_ctx = @cxx &ctx->exe_ctx_ref
    try
        curp = bswap(run_expr(dbg,"\$s7",exe_ctx))
        next = run_expr(dbg,"(uint32_t)next",exe_ctx)
        state = run_expr(dbg,"(uint32_t)newstate",exe_ctx)
        if !haskey(active_threads,curp) || !haskey(active_threads, next)
            return false
        end
        cur = active_threads[curp]
        next = active_threads[next]
        push!(events,(cur,next))
        if state == S_SLEEP
            id = length(events)
            blocked_threads[curp] = id
        end
    catch e
        println(e)
        return true
    end
    if (length(events) % 100) == 0
        process_and_plot() |> display
        println()
    end
    return false
end
SetBreakpointAtLoc(f3,target,"thread.c",657)

function f4(env, ctx, id, loc)
    ctx = pcpp"lldb_private::StoppointCallbackContext"(ctx)
    exe_ctx = @cxx &ctx->exe_ctx_ref
    try
        thread = run_expr(dbg,"(uint32_t)target",exe_ctx)
        if !haskey(blocked_threads,thread)
            return false
        end
        start = blocked_threads[thread]
        delete!(blocked_threads, thread)
        last = length(events)
        push!(block_events,(active_threads[thread],start,last))
    catch e
        println(e)
        return true
    end
    return false
end
SetBreakpoint(f4,target,"thread_make_runnable")

using Compose

function plot_data(events, block_events, all_threads; block_color="red", thread_color="white")
    nthreads = length(all_threads)
    npoints = length(events)
    points = Array((Float64,Float64),2*npoints)
    twidth = 1/(nthreads+2)
    theight = 1/(npoints+2)
    for (i,e) in enumerate(events)
        (a,b) = e
        points[2*i-1] = (twidth + a*twidth, i*theight)
        points[2*i] = (twidth + b*twidth, i*theight)
    end
    x = []
    for (t,s,e) in block_events
        push!(x,Compose.line([(twidth + t*twidth, s*theight),
                     (twidth + t*twidth, e*theight)]))
    end
    Compose.compose(Compose.context(),
        Compose.compose(Compose.context(),x...,Compose.stroke(block_color)),
        Compose.compose(Compose.context(),Compose.line(points),Compose.stroke(thread_color)),
        )
end

function find_mapping(events2,bmap,id)
    while !haskey(bmap,id)
        id = id+1
        if id > length(events2)
            return length(events2)
        end
    end
    bmap[id]
end



function process_data()
    global events, block_events
    events3 = collect(enumerate(events))
    events4 = filter(events3) do t
        (a,(b,c)) = t
        b != c
    end

    bmap = Dict{Int,Int}()
    for (i,(a,_)) in enumerate(events4)
        bmap[a] = i
    end

    block_events3 = filter(block_events) do t
        (a,b,c) = t
        b != c
    end

    events2 = [x for (a,x) in events4]
    block_events2 = [(a,find_mapping(events2,bmap,b),find_mapping(events2,bmap,c)) for (a,b,c) in block_events3]

    events2, block_events2
end

function process_and_plot(;args...)
    events2, block_events2 = process_data()
    plot_data(events2, block_events2, all_threads; args...)
end

#=
compose(context(),line(plot_data(events2[i:(i+200)],all_threads)),stroke("black"))

using Reel
frames = Frames(MIME("image/png"), fps=10)

for i=1:length(events2)-200
    push!(frames, compose(context(),line(plot_data(events2[i:(i+200)],all_threads)),stroke("black")))
end

frames

film = roll(render, fps=30, duration=2)
=#
