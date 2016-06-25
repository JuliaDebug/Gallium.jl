using Gallium
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
