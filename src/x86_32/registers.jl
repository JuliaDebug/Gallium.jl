module X86_32
  using ..Registers
  abstract RegisterSet <: Registers.RegisterSet
  import Base: copy

  immutable X86_32Arch <: Registers.Architecture
  end
  Registers.intptr(::X86_32Arch) = UInt32
  
  # See https://www.uclibc.org/docs/psABI-i386.pdf
  const dwarf_numbering = Dict{Int, Symbol}(
  0  => :eax,   1  => :ecx,   2  => :edx,
  3  => :ebx,   4  => :esp,   5  => :ebp,
  6  => :esi,   7  => :edi,   8  => :eip,
  9  => :eflags,
  # 10 is reserved
  (11+i => Symbol("st$i") for i = 0:7)...,
  # 19-20 are reserved
  (21+i => Symbol("xmm$i") for i = 0:7)...,
  (29+i => Symbol("mm$i") for i = 0:7)...,
  39 => :mxcsr,
  40 => :es, 41 => :cs, 42 => :ss,
  43 => :ds, 44 => :fs, 45 => :gs,
  # 46-47 are reserved
  48 => :tr, 49 => :ldtr
  # 50-92 are reserved
  )
  const inverse_dwarf = map(p->p[2]=>p[1], dwarf_numbering)  
  const basic_regs = 0:9

  const gdb_numbering = Dict{Int, Symbol}(
    Dict(i=>dwarf_numbering[i] for i in 0:9)...,
    10 => :cs, 11 => :ss, 12 => :ds,
    13 => :es, 14 => :fs, 15 => :gs,
    (16+i => Symbol("st$i") for i = 0:7)...,
    24 => :fctrl, 25 => :fstat, 26 => :ftag, 
    27 => :fiseg, 28 => :fioff, 29 => :foseg,
    30 => :fooff, 31 => :fop,
    (32+i => Symbol("xmm$i") for i = 0:7)...,
    40 => :mxcsr,
  )
  const inverse_gdb = map(p->p[2]=>p[1], gdb_numbering)

  function Registers.get_dwarf(::X86_32Arch, regs, sym)
    get_dwarf(regs, inverse_dwarf[sym])  
  end

  function Registers.set_dwarf!(::X86_32Arch, RC, sym, val)
    set_dwarf!(RC, inverse_dwarf[sym], val)
  end

  function Registers.get_syscallarg(::X86_32Arch, regs, idx)
        @assert 1 <= idx <= 6
        get_dwarf(regs, [:ebx, :ecx, :edx, :esi, :edi, :ebp][idx])
  end

  # This operation can be performance critical, precompute it.
  const dwarf2gdbmap = [inverse_gdb[dwarf_numbering[regno]] for regno in basic_regs]
  dwarf2gdb(regno) = regno in basic_regs ? dwarf2gdbmap[regno+1] :
    inverse_gdb[dwarf_numbering[regno]]

end
