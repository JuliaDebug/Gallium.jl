module X86_64
  using ..Registers
  abstract RegisterSet <: Registers.RegisterSet
  using MachO

  # See zhttp://www.x86-64.org/documentation/abi-0.99.7.pdf
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
  58 => Symbol("fs.base"), 59 => Symbol("gs.base"),
  62 => :tr, 63 => :ldtr, 64 => :mxcsr, 65 => :fcw,
  66 => :fsw)
  const inverse_dwarf = map(p->p[2]=>p[1], dwarf_numbering)
  const basic_regs = 0:16

  const gdb_numbering = Dict{Int, Symbol}(
    (i => dwarf_numbering[i] for i in basic_regs)...)
  const inverse_gdb = map(p->p[2]=>p[1], gdb_numbering)

  # Basic Register Set
  const RegT = RegisterValue{UInt64}
  @eval type BasicRegs <: RegisterSet
      $(Expr(:block, (
        :($(dwarf_numbering[i]) :: RegT) for i in basic_regs
      )...))
      BasicRegs() = new()
  end
  Registers.ip(regs::RegisterSet) = regs.rip
  Registers.set_ip!(regs::RegisterSet, ip) = regs.rip = RegisterValue{UInt64}(ip)
  Registers.set_sp!(regs::RegisterSet, sp) = regs.rsp = RegisterValue{UInt64}(sp)
  function Registers.invalidate_regs!(regs::BasicRegs)
      for fieldi = 1:nfields(regs)
          setfield!(regs, fieldi, Registers.invalidated(getfield(regs, fieldi)))
      end
  end

  function Base.copy(regs::BasicRegs)
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

  function Registers.set_dwarf!(regs::BasicRegs, reg, value)
      (reg <= endof(basic_regs)) && setfield!(regs, reg+1, RegisterValue{UInt64}(value))
  end

  function Registers.get_dwarf(regs::BasicRegs, reg)
      (reg <= endof(basic_regs)) ? getfield(regs, reg+1) :
        RegisterValue{UInt64}(0, 0)
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

end
