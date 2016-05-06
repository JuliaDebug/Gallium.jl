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

function write_mem
end

function mapped_file
end

# Remapping
immutable Remap
    addr::RemotePtr{Void}
    size::UInt64
    data::Vector{UInt8}
end

immutable TransparentRemap{T}
    inferior::T
    remaps::Vector{Remap}
end

function load{T}(tr::TransparentRemap, ptr::RemotePtr{T})
    sz = sizeof(T)
    for remap in tr.remaps
        if UInt(remap.addr) <= UInt(ptr) &&
            UInt(ptr) + sz <= UInt(remap.addr) + remap.size
            offs = UInt(ptr) - UInt(remap.addr)
            return unsafe_load(Ptr{T}(pointer(remap.data)+offs))
        end
    end
    unsafe_load(tr.inferior, ptr)
end

function write_mem{T}(tr::TransparentRemap, ptr::RemotePtr{T}, val::T)
    sz = sizeof(T)
    for remap in tr.remaps
        if UInt(remap.addr) <= UInt(ptr) &&
            UInt(ptr) + sz <= UInt(remap.addr) + remap.size
            offs = UInt(ptr) - UInt(remap.addr)
            unsafe_store!(Ptr{T}(pointer(remap.data)+offs), val)
            return nothing
        end
    end
    write_mem(tr.inferior, ptr, val)
    nothing
end
