export RemotePtr, RemoteCodePtr
import Base: +, -

"""
Represents a debugging session with potentially one or more inferiors (e.g. 
  multiple threads/processes in a progess group).
"""
abstract RemoteSession
immutable LocalSession; end

immutable RemotePtr{T}
    ptr::UInt64
end
Base.convert(::Type{UInt64}, x::RemotePtr{UInt64}) = UInt64(x.ptr)
Base.convert(::Type{UInt64}, x::RemotePtr) = UInt64(x.ptr)
Base.convert{T<:RemotePtr}(::Type{T}, x::RemotePtr) = T(x.ptr)
(::Type{RemotePtr{T}}){T}(x::RemotePtr) = RemotePtr{T}(x.ptr)
for f in (:+, :-)
    @eval ($f){T}(ptr::RemotePtr{T},i::Integer) = RemotePtr{T}(($f)(ptr.ptr,i))
    @eval ($f){T}(i::Integer,ptr::RemotePtr{T}) = RemotePtr{T}(($f)(i,ptr.ptr))
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
Base.convert(::Type{RemotePtr{Void}},x::RemoteCodePtr) = RemotePtr{Void}(x.ptr)
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
immutable FakeMemorySession
    memory_maps::Vector{Tuple{UInt64,Vector{UInt8}}}
end

function load{T}(mem::FakeMemorySession, ptr::RemotePtr{T})
    for (addr, data) in mem.memory_maps
        if addr <= UInt64(ptr) <= addr + sizeof(data)
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

function getregs
end

function continue!
end

function single_step!
end

function step_until_bkpt!
end

function read_exe
end
