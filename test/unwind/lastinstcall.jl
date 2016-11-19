using Gallium, ELF, ObjFileBase
using Gallium: set_dwarf!
using Base.Test

eval(Gallium, :(allow_bad_unwind=false))

include("utils.jl")

# Test for a call at the end of a function. We're using X86 here for convenience
# but since we're not actually executing this test, it could be made to work
# on all platforms.
build_executable("call_at_end");

modules, _ = build_simple_mod_map("inputs/call_at_end.out")
RC, sess = one_call_fake_stack(modules, 0x8)
set_dwarf!(RC, :rip, compute_addr(modules, "callee"))

# Now do the stackwalk
stack, RCs = Gallium.stackwalk(RC, sess, modules)

# Verify that we got the right functions
@test length(stack) == 2
@test Gallium.symbolicate(sess, modules, stack[1])[2] == "_start"
@test Gallium.symbolicate(sess, modules, stack[2])[2] == "callee"
