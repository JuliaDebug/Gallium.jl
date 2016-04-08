module Registers

  export RegisterValue, RegisterSet
  abstract RegisterSet

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
  getindex(v::RegisterValue) = v.value & v.mask
  isvalid{T}(v::RegisterValue{T}) = v.mask == (-1%T)
  invalidated{T}(v::RegisterValue{T}) = RegisterValue{T}(v.value, 0)

  # RegisterSets should ideally support the following operations
  export invalidate_regs!, set_sp!, set_ip!, set_dwarf!, get_dwarf!
  
  function ip; end
  function invalidate_regs!; end
  function set_sp!; end
  function set_ip!; end
  function set_dwarf!; end
  function get_dwarf; end

end
