using Gallium, ELF, ObjFileBase
using Gallium: set_dwarf!
using Base.Test

# N.B.: This test fails on most currently available systems due to a bug in
#       the linker (https://sourceware.org/bugzilla/show_bug.cgi?id=20830)

eval(Gallium, :(allow_bad_unwind=false))

include("utils.jl")

build_shlib("plt-dyn")
build_executable("plt", ["plt-dyn.so"])

# Build module map
modules, h = build_simple_mod_map("inputs/plt.out")

# First check the call to func2, which goes through .plt
RC, sess = one_call_fake_stack(modules, 0xc)
# First instruction in func2@plt
set_dwarf!(RC, :rip, compute_section_addr(modules, h, ".plt") + 0x10)

# Now do the stackwalk
stack, RCs = Gallium.stackwalk(RC, sess, modules)

@show Gallium.symbolicate(sess, modules, stack[1])[2]
@show Gallium.symbolicate(sess, modules, stack[2])[2]


# Verify that we got the right functions
@test length(stack) == 2
@test Gallium.symbolicate(sess, modules, stack[1])[2] == "_start"
@test Gallium.symbolicate(sess, modules, stack[2])[2] == "PLT entry for func2"

# Then check the call to func1, which goes through .plt.got
RC, sess = one_call_fake_stack(modules, 0xc)
# First instruction in func1@plt
set_dwarf!(RC, :rip, compute_section_addr(modules, h, ".plt.got") + 0x0)

# Now do the stackwalk
stack, RCs = Gallium.stackwalk(RC, sess, modules)

# Verify that we got the right functions
@test length(stack) == 2
@test Gallium.symbolicate(sess, modules, stack[1])[2] == "_start"
@test Gallium.symbolicate(sess, modules, stack[2])[2] == "PLT entry for func1"
