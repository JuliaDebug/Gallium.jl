using Gallium
include("Hooking.jl")
# Breakpointing needs to be run in a separate process since it overrides methods
# for testing purposes
run(`$(Base.julia_cmd()) -f $(joinpath(dirname(@__FILE__),"breakpointing.jl"))`)
