using Gallium, ELF, ObjFileBase
using Gallium: set_dwarf!
using Base.Test

eval(Gallium, :(allow_bad_unwind=false))

function build_executable(name)
    cd("inputs") do
      run(`llvm-mc -filetype=obj -o $name.o $name.S`)
      run(`ld -o $name.out $name.o`)
    end
end

# Test for a call at the end of a function. We're using X86 here for convenience
# but since we're not actually executing this test, it could be made to work
# on all platforms.
build_executable("call_at_end");

# Build module map
base = 0x0000000000400000
fn = "inputs/call_at_end.out"
h = readmeta(IOBuffer(open(Base.Mmap.mmap, fn)))
modules = Dict{RemotePtr{Void},Any}(
   RemotePtr{Void}(base) => Gallium.GlibcDyldModules.mod_for_h(h, base, fn)
)

# Build fake stack
stacktop = 0x0000000000500000
(h, base, sym)  = Gallium.lookup_sym(nothing, modules, "_start")
startaddr = Gallium.compute_symbol_value(h, base, sym)
stack = reinterpret(UInt8,
  UInt64[
    # Return address pushed by the call
    UInt64(startaddr)+0x8
  ])
sess = Gallium.FakeMemorySession([(stacktop-sizeof(stack), stack)],Gallium.X86_64.X86_64Arch())

# Build fake register context
RC = Gallium.X86_64.BasicRegs()
(h, base, sym) = Gallium.lookup_sym(nothing, modules, "callee")
calleeaddr = Gallium.compute_symbol_value(h, base, sym)
set_dwarf!(RC, :rip, UInt64(calleeaddr))
set_dwarf!(RC, :rsp, stacktop - sizeof(stack))

# Now do the stackwalk
stack, RCs = Gallium.stackwalk(RC, sess, modules)

# Verify that we got the right functions
@test length(stack) == 2
@test Gallium.symbolicate(sess, modules, stack[1])[2] == "_start"
@test Gallium.symbolicate(sess, modules, stack[2])[2] == "callee"
