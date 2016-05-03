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
