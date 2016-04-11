module Registers

  export RegisterValue, RegisterSet
  abstract RegisterSet
  import Base: convert, getindex, -, +

  """
  Represents the value of a machine register.

  T is the architecturally defined maximum size of the register.
  We keep both the register's value as well as a bitmask of which
  bits in the value we know to be valid.
  """
  immutable RegisterValue{T}
      value::T
      mask::T
  end
  convert{T<:Integer}(::Type{T}, r::RegisterValue) = convert(T,r[])
  convert{T}(::Type{RegisterValue{T}},value::T) = RegisterValue{T}(value, -1%T)
  getindex(v::RegisterValue) = v.value & v.mask
  isvalid{T}(v::RegisterValue{T}) = v.mask == (-1%T)
  invalidated{T}(v::RegisterValue{T}) = RegisterValue{T}(v.value, 0)
  for op in (:+, :-)
      @eval ($op)(r::RegisterValue, x::Integer) = RegisterValue(($op)(r.value, x), r.mask)
      @eval ($op)(x::Integer, r::RegisterValue) = RegisterValue(($op)(x, r.value), r.mask)
  end
  
  function Base.show(io::IO, r::RegisterValue)
      value = hex(r[], 2sizeof(r[]))
      print_with_color(:green, io, "0x")
      for (i,c) in enumerate(value)
          shift = (8sizeof(r[]) - 4i)
          b = (r.mask & (UInt64(0xf) << shift)) >> shift
          print_with_color((b == 0xf) ? :green :
                           (b == 0x0) ? :red :
                           :yellow, io, string(c))
      end
  end

  # RegisterSets should ideally support the following operations
  export invalidate_regs!, set_sp!, set_ip!, set_dwarf!, get_dwarf
  
  function ip end
  function invalidate_regs! end
  function set_sp! end
  function set_ip! end
  function set_dwarf! end
  function get_dwarf end

end
