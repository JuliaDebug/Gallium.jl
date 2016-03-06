using Gallium
using ObjFileBase
using ELF
bigfib(n) = ((BigInt[1 1; 1 0])^n)[2,1]
faddr = Hooking.get_function_addr(bigfib, Tuple{Int64})
data = copy(ccall(:jl_get_dobj_data, Any, (Ptr{Void},), faddr))
buf = IOBuffer(data, true, true)
h = readmeta(buf)
ELF.relocate!(buf, h)
dbgs = debugsections(h)
s = DWARF.finddietreebyname(dbgs, "bigfib")
include("$(Pkg.dir())/DIDebug/src/DIDebugLite.jl")
DIDebug.process_SP(s.tree.children[1], s.strtab)
