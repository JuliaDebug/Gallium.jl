module X86_64
  using ..Registers
  abstract RegisterSet <: Registers.RegisterSet
  using MachO
  import Base: copy

  immutable X86_64Arch <: Registers.Architecture
  end
  Registers.intptr(::X86_64Arch) = UInt64

  # See http://www.x86-64.org/documentation/abi-0.99.7.pdf
  const dwarf_numbering = Dict{Int, Symbol}(
  0  => :rax,   1  => :rdx,   2  => :rcx,
  3  => :rbx,   4  => :rsi,   5  => :rdi,
  6  => :rbp,   7  => :rsp,
  (i => Symbol("r$i") for i = 8:15)...,
  16 => :rip,
  (17+i => Symbol("xmm$i") for i = 0:15)...,
  (33+i => Symbol("st$i") for i = 0:7)...,
  (41+i => Symbol("mm$i") for i = 0:7)...,
  49 => :rflags,
  50 => :es, 51 => :cs, 52 => :ss,
  53 => :ds, 54 => :fs, 55 => :gs,
  58 => :fs_base, 59 => :gs_base,
  62 => :tr, 63 => :ldtr, 64 => :mxcsr, 65 => :fcw,
  66 => :fsw)
  const inverse_dwarf = map(p->p[2]=>p[1], dwarf_numbering)
  const basic_regs = 0:16
  const extended_registers = 17:32

  const gdb_numbering = Dict{Int, Symbol}(
     0 => :rax, 1 => :rbx, 2 => :rcx, 3 => :rdx,
     4 => :rsi, Dict(i=>dwarf_numbering[i] for i in 5:16)...,
    17 => :rflags, 18 => :cs, 19 => :ds, 20 => :es, 21 => :fs, 22 => :gs,
    #Dict(23+i => Symbol("st$i") for i = 0:7)...,
    31 => :fctrl, 32 => :fstat, 33 => :ftag, 34 => :fiseg, 35 => :fioff,
    36 => :foseg, 37 => :fooff, 38 => :fop,
    Dict(39+i => Symbol("xmm$i") for i = 0:15)...
  )
  const inverse_gdb = map(p->p[2]=>p[1], gdb_numbering)

  const seh_numbering = Dict{Int, Symbol}(
     0 => :rax, 1 => :rcx, 2 => :rdx, 3 => :rbx, 4 => :rsp, 5 => :rbp,
     6 => :rsi, 7 => :rdi, (i => Symbol("r$i") for i = 8:15)...
  )
  const inverse_seh = map(p->p[2]=>p[1], seh_numbering)

  const kernel_order = [
    [Symbol("r$r") for r in 15:-1:12]; :rbp; :rbx;
    [Symbol("r$r") for r in 11:-1:8]; :rax; :rcx;
    :rdx; :rsi; :rdi; :orig_rax; :rip; :cs; :eflags;
    :rsp; :ss; :fs_base; :gs_base; :ds; :es; :fs; :gs
  ]
  const kernel_numbering = Dict(sym=>idx for (idx,sym) in enumerate(kernel_order))

  # This operation can be performance critical, precompute it.
  const dwarf2gdbmap = [inverse_gdb[dwarf_numbering[regno]] for regno in basic_regs]
  dwarf2gdb(regno) = regno in basic_regs ? dwarf2gdbmap[regno+1] :
    inverse_gdb[dwarf_numbering[regno]]

  # Basic Register Set
  const RegT = RegisterValue{UInt64}
  const ExtendedRegT = RegisterValue{UInt128}
  @eval type BasicRegs <: RegisterSet
      $(Expr(:block, (
        :($(dwarf_numbering[i]) :: RegT) for i in basic_regs
      )...))
      BasicRegs() = new()
  end
  type ExtendedRegs <: RegisterSet
      basic::BasicRegs
      xsave_state::NTuple{832, UInt8}
  end
  Registers.getarch(::Union{BasicRegs,ExtendedRegs}) = X86_64Arch()

  import ..Registers: ip, set_ip!, set_sp!, invalidate_regs!

  ip(regs::BasicRegs) = regs.rip
  set_ip!(regs::BasicRegs, ip) = regs.rip = RegisterValue{UInt64}(ip)
  set_sp!(regs::BasicRegs, sp) = regs.rsp = RegisterValue{UInt64}(sp)
  function invalidate_regs!(regs::BasicRegs)
      for fieldi = 1:nfields(regs)
          setfield!(regs, fieldi, Registers.invalidated(getfield(regs, fieldi)))
      end
  end

  for f in (:ip, :set_ip!, :set_sp!, :invalidate_regs!)
    @eval $(f)(regs::ExtendedRegs, args...) = $(f)(regs.basic, args...)
  end

  copy(regs::ExtendedRegs) = ExtendedRegs(copy(regs.basic),regs.xsave_state)
  function copy(regs::BasicRegs)
      ret = BasicRegs()
      for i = 1:nfields(regs)
          setfield!(ret, i, getfield(regs, i))
      end
      ret
  end

  function Base.show(io::IO, regs::BasicRegs)
      for (i,reg) in enumerate(fieldnames(typeof(regs)))
          println(io," "^(3-length(string(reg))),reg," ",getfield(regs, i))
      end
  end

  function Registers.set_dwarf!(regs::BasicRegs, reg::Integer, value)
      (reg <= last(basic_regs)) && setfield!(regs, reg+1, RegisterValue{UInt64}(value))
  end

  function Registers.get_dwarf(regs::BasicRegs, reg::Integer)
      (reg <= last(basic_regs)) ? getfield(regs, reg+1) :
        RegisterValue{UInt64}(0, 0)
  end

  function Registers.get_dwarf(regs::ExtendedRegs, reg::Integer)
      if reg <= last(basic_regs)
        get_dwarf(regs.basic, reg)
      elseif reg <= last(extended_registers)
        # XMM registers
        startoff = 160+16*(reg - first(extended_registers))
        endoff = startoff + 16
        reinterpret(UInt128,
          reinterpret(UInt8,[regs.xsave_state])[startoff:endoff])[]
      else
        error("Extraction not yet implemented for this register")
      end
  end

  function Registers.set_dwarf!(regs::ExtendedRegs, reg::Integer, value)
    if reg <= last(basic_regs)
      set_dwarf!(regs.basic, reg, value)
    else
      error("Extraction not yet implemented for this register")
    end
  end

  function Registers.get_dwarf(::X86_64Arch, regs, sym)
    get_dwarf(regs, inverse_dwarf[sym])
  end

  function Registers.set_dwarf!(::X86_64Arch, RC, sym, val)
    set_dwarf!(RC, inverse_dwarf[sym], val)
  end

  function Registers.get_syscallarg(::X86_64Arch, regs, idx)
    @assert 1 <= idx <= 6
    get_dwarf(regs, [:rdi, :rsi, :rdx, :r10, :r8, :r9][idx])
  end

  const state_64_regs = [:rax, :rbx, :rcx, :rdx, :rdi, :rsi, :rbp, :rsp,
    (Symbol("r$i") for i = 8:15)..., :rip, #= :rflags, :cs, :fs, :gs =#]
  function BasicRegs(thread::MachO.thread_command)
    RC = BasicRegs()
    if thread.flavor == MachO.x86_THREAD_STATE64
      for (i,reg) in enumerate(state_64_regs)
        set_dwarf!(RC, inverse_dwarf[reg], thread.data[i])
      end
    else
      error("Unknown flavor")
    end
    return RC
  end

  include("instemulate.jl")
end
