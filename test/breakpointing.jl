#
# This test replaces a method in Gallium. It should be run in a separate
# process from other tests.
#

using Gallium
using Base.Test
hit_counter = 0
function Gallium.breakpoint_hit(hook, RC)
    global hit_counter
    hit_counter += 1
    nothing
end

function simple(x, y)
    x+y
end

Gallium.breakpoint(simple, Tuple{Int64, Int64})
@test simple(1, 2) == 3
@test hit_counter == 1
@test simple(1.0, 2.0) == 3.0
@test hit_counter == 1

breakmeth(x, y) = x+y
breakmeth(x::Float64, y::Float64) = x*y

hit_counter = 0
Gallium.breakpoint(which(breakmeth, Tuple{Int64, Int64}))
@test breakmeth(1, 2) == 3
@test hit_counter == 1
breakmeth(Float32(1), Float32(2)) # @test == Float32(3)
@test hit_counter == 2
@test simple(1.0, 2.0) == 3.0
@test hit_counter == 2

which_counter = 0
hit_counter = 0
function somefunc()
    global which_counter
    which_counter += 1
    return nothing
end
Gallium.breakpoint(somefunc)
@test somefunc() == nothing
@test which_counter == 1
@test hit_counter == 1

#Now add a method
function somefunc(x::Int)
    global which_counter
    which_counter += x
    return nothing
end
@test somefunc(10) == nothing
@test which_counter == 11
@test hit_counter == 2

# Now test line-based breakpointing
hit_counter = 0
line = @__LINE__ + 3
Gallium.breakpoint("breakpointing.jl", line)
function testlinebreak()
    gcd(10, 20) # Breakpoint is here
end
@test testlinebreak() == gcd(10, 20)
@test hit_counter == 1
