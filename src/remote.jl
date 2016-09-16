export RemotePtr, RemoteCodePtr
import Base: +, -

"""
Represents a debugging session with potentially one or more inferiors (e.g. 
  multiple threads/processes in a progess group).
"""
abstract RemoteSession
immutable LocalSession; end

immutable RemotePtr{T,intptrT}
    ptr::intptrT
end
(::Type{RemotePtr{T}}){T}(arg) = RemotePtr{T,UInt64}(arg)
(::Type{T}){T<:RemotePtr}(x::RemotePtr) = T(x.ptr)
Base.convert(::Type{UInt64}, x::RemotePtr{UInt64}) = UInt64(x.ptr)
Base.convert(::Type{UInt64}, x::RemotePtr) = UInt64(x.ptr)
Base.convert{T<:RemotePtr}(::Type{T}, x::RemotePtr) =
    ((T === RemotePtr) ? x : T(x.ptr))::T
for f in (:+, :-)
    @eval ($f){T<:RemotePtr}(ptr::T,i::Integer) = T(($f)(ptr.ptr,i))
    @eval ($f){T<:RemotePtr}(i::Integer,ptr::T) = T(($f)(i,ptr.ptr))
end
Base.:(==)(x::Integer,y::RemotePtr) = x == y.ptr
Base.:(==)(x::RemotePtr,y::Integer) = x.ptr == y
Base.:(==)(x::RemotePtr,y::RemotePtr) = x.ptr == y.ptr
Base.isless(x::RemotePtr,y::RemotePtr) = isless(UInt64(x),UInt64(y))

# TODO: It's not entirely clear that this distinction is needed or useful,
# but it's present in RR, so is included in this abstract interface for
# compatibility
immutable RemoteCodePtr
    ptr::UInt64
end
Base.convert(::Type{UInt64},x::RemoteCodePtr) = x.ptr
Base.convert{T}(::Type{RemotePtr{Void,T}},x::RemoteCodePtr) = RemotePtr{Void,T}(x.ptr)
Base.convert{T}(::Type{RemotePtr{T}},x::RemoteCodePtr) = RemotePtr{T}(x.ptr)
Base.convert(::Type{RemotePtr},x::RemoteCodePtr) = RemotePtr{Void}(x.ptr)

function load{T}(session::LocalSession, ptr::RemotePtr{T})
    unsafe_load(Ptr{T}(ptr.ptr))
end

function store!{T}(session::LocalSession, ptr::RemotePtr{T}, val::T)
    unsafe_store!(Ptr{T}(ptr.ptr), val)
end

function write_mem
end

function mapped_file
end

function segment_base
end

# Simple session to put some data at specific addresses
immutable FakeMemorySession{T}
    memory_maps::Vector{Tuple{UInt64,Vector{UInt8}}}
    arch
    asid::T
end
Base.show(io::IO, sess::FakeMemorySession) = print(io,"FakeMemorySession(arch=$(sess.arch),asid=$(sess.asid))")
FakeMemorySession(maps,arch) = FakeMemorySession{Void}(maps, arch, nothing)
current_asid(sess::FakeMemorySession) = sess.asid
getarch(sess::FakeMemorySession) = sess.arch

function load{T}(mem::FakeMemorySession, ptr::RemotePtr{T})
    for (addr, data) in mem.memory_maps
        if addr <= UInt64(ptr) <= addr + sizeof(data) - sizeof(T)
            start = (UInt64(ptr)-addr)
            return reinterpret(T,data[1+start:start+sizeof(T)])[]
        end
    end
    error("Address $ptr not found")
end

function store!{T}(session::FakeMemorySession, ptr::RemotePtr{T}, val::T)
    for (addr, data) in mem.memory_maps
        if addr <= UInt64(ptr) <= addr + sizeof(data)
            start = (UInt64(ptr)-addr)
            data[1+start:start+sizeof(T)] = reinterpret(UInt8,[val])
        end
    end
end

function getarch(s::LocalSession)
    sizeof(Ptr{Void}) == 8 ? X86_64.X86_64Arch() : X86_64.X86_32Arch()
end

function getregs
end

function get_thread_area_base
end

function continue!
end

function single_step!
end

function step_until_bkpt!
end

function read_exe
end
