using Cxx
using Gallium

if isdefined(Base, :active_repl)
    include(Pkg.dir("Cxx","src","CxxREPL","replpane.jl"))
    include(Pkg.dir("Gallium","src","lldbrepl.jl"))
end

const dbg = debugger()
RunLLDBRepl(dbg)

function Base.CFILE(fd::RawFD, mode)
    @unix_only FILEp = ccall(:fdopen, Ptr{Void}, (Cint, Ptr{UInt8}), convert(Cint, fd.fd), mode)
    @windows_only FILEp = ccall(:_fdopen, Ptr{Void}, (Cint, Ptr{UInt8}), convert(Cint, fd.fd), mode)
    systemerror("fdopen", FILEp == C_NULL)
    CFILE(FILEp)
end

SetOutputFileHandle(dbg,CFILE(Base._fd(STDOUT),Base.modestr(false,true)), false)
SetErrorFileHandle(dbg,CFILE(Base._fd(STDERR),Base.modestr(false,true)), false)

lldb_exec(dbg,"target create ~/os161/root/kernel")
lldb_exec(dbg,"process connect connect://localhost:2000")
const target = targets(dbg)[0]
