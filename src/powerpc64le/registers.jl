module PowerPC64
  using ..Registers
  abstract RegisterSet <: Registers.RegisterSet
  using MachO
  import Base: copy

  immutable PowerPC64Arch <: Registers.Architecture
  end
  Registers.intptr(::PowerPC64Arch) = UInt64

  # See http://refspecs.linuxfoundation.org/ELF/ppc64/PPC-elf64abi.html
  const dwarf_numbering = Dict{Int, Symbol}(
    (i => Symbol("r$i") for i = 0:31)...,
    (32+i => Symbol("f$i") for i = 0:31)...,
    64 => :cr, 65 => :fpscr, 101 => :xer, 108 => :lr,
    109 => :ctr, 110 => :pc
  )
  const inverse_dwarf = map(p->p[2]=>p[1], dwarf_numbering)
  const basic_regs = sort(collect(keys(dwarf_numbering)))
  const extended_registers = 17:32

  const gdb_numbering = Dict{Int, Symbol}(
    (i => Symbol("r$i") for i = 0:31)...,
    (32+i => Symbol("f$i") for i = 0:31)...,
    64 => :pc, 65 => :msr, 66 => :cr, 67 => :lr,
    68 => :ctr, 69 => :xer, 70 => :fpscr
  )
  const inverse_gdb = map(p->p[2]=>p[1], gdb_numbering)

  const kernel_order = [
    [Symbol("r$r") for r in 0:31]...,
    :pc, :msr, :orig_gpr, :ctr, :lr, :xer, :cr, :softe,
    :trap, :dar, :dsisr, :result
  ]
  const kernel_numbering = Dict(sym=>idx for (idx,sym) in enumerate(kernel_order))

  # Basic Register Set
  const RegT = RegisterValue{UInt64}
  const ExtendedRegT = RegisterValue{UInt128}
  @eval type BasicRegs <: RegisterSet
      $(Expr(:block, (
        :($(dwarf_numbering[i]) :: RegT) for i in basic_regs
      )...))
      BasicRegs() = new()
  end
  Registers.getarch(::BasicRegs) = PowerPC64Arch()

  import ..Registers: ip, set_ip!, set_sp!, invalidate_regs!

  ip(regs::BasicRegs) = regs.pc
  set_ip!(regs::BasicRegs, ip) = regs.pc = RegisterValue{UInt64}(ip)
  set_sp!(regs::BasicRegs, sp) = regs.r1 = RegisterValue{UInt64}(sp)
  function invalidate_regs!(regs::BasicRegs)
      for fieldi = 1:nfields(regs)
          setfield!(regs, fieldi, Registers.invalidated(getfield(regs, fieldi)))
      end
  end

  function copy(regs::BasicRegs)
      ret = BasicRegs()
      for i = 1:nfields(regs)
          setfield!(ret, i, getfield(regs, i))
      end
      ret
  end

  function Base.show(io::IO, regs::BasicRegs)
      for (i,reg) in enumerate(fieldnames(typeof(regs)))
          println(io," "^(5-length(string(reg))),reg," ",getfield(regs, i))
      end
  end

  function Registers.set_dwarf!(regs::BasicRegs, reg::Integer, value)
      (reg <= last(basic_regs)) && setfield!(regs, reg+1, RegisterValue{UInt64}(value))
  end

  function Registers.get_dwarf(regs::BasicRegs, reg::Integer)
      (reg <= last(basic_regs)) ? getfield(regs, reg+1) :
        RegisterValue{UInt64}(0, 0)
  end

  function Registers.get_dwarf(::PowerPC64Arch, regs, sym)
    get_dwarf(regs, inverse_dwarf[sym])
  end

  function Registers.set_dwarf!(::PowerPC64Arch, RC, sym, val)
    set_dwarf!(RC, inverse_dwarf[sym], val)
  end

  function Registers.get_syscallarg(::PowerPC64Arch, regs, idx)
    @assert 1 <= idx <= 6
    get_dwarf(regs, [:rdi, :rsi, :rdx, :r10, :r8, :r9][idx])
  end

end
