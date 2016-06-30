using Gallium
using Base.Test
include("Hooking.jl")
# Breakpointing needs to be run in a separate process since it overrides methods
# for testing purposes
run(`$(Base.julia_cmd()) -f $(joinpath(dirname(@__FILE__),"breakpointing.jl"))`)

# #self# needs to be captured properly (for clousures)
fclosure,gclosure = let y = 2
    (()->(@Base._noinline_meta; y),()->(@Base._noinline_meta; y=3))
end

global hit_breakpoint = false
@conditional breakpoint(fclosure, Tuple{}) (global hit_breakpoint = true; false)

@test fclosure()==2
@test hit_breakpoint

# Breakpointing functions with keyword arguments
hit_breakpoint = false
@noinline fkeywords(x; a = 2) = x + a
@conditional breakpoint(fkeywords, Tuple{Int64}) (global hit_breakpoint = true; false)

@test fkeywords(1) == 3
@test hit_breakpoint

# Floating point value recovery
hit_breakpoint = false
function f131(x)
    y=x+1
    z=2y
    return z
end
@conditional breakpoint(f131) (global hit_breakpoint = true; (@test x==3.0); false)
f131(3.0)
@test hit_breakpoint

# Floating point value recovery in breakpoint()
@noinline function do_xmmbptest()
    # Manually do what's done in breakpoint() to look at the stack
    RC = Hooking.getcontext()
    # -1 to skip breakpoint (getcontext is inlined)
    stack, RCs = Gallium.stackwalk(RC; fromhook = false)
    frame = collect(filter(x->isa(x,Gallium.JuliaStackFrame),stack))[end-1]
    id = findfirst(sym->sym==:y,frame.linfo.def.lambda_template.slotnames)
    # For now only test this on OS X since it doesn't work elsewhere
    # TODO: Figure out why
    if is_apple()
        @test 2.0 == get(frame.env.locals[id])
    end
end


function xmmbptest(x)
    y = x+1.0
    do_xmmbptest()
    # Make sure to keep this live
    y
end
@test xmmbptest(1.0) == 2.0

# Floating point value recovery in breakpoint_on_error()
using Gallium
function xmmerrtest(x)
    y = x+1.0
    error(y)
    y
end
hit_breakpoint = false
Gallium.breakpoint_on_error()
push!(Gallium.bp_on_error_conditions,:(is_apple() && @test y == 2.0; global hit_breakpoint = true; false))
try; xmmerrtest(1.0); end
@test hit_breakpoint
empty!(Gallium.bp_on_error_conditions)
Gallium.breakpoint_on_error(false)
