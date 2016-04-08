module X86_64
  using ..Registers
  abstract RegisterSet <: Registers.RegisterSet

  # See zhttp://www.x86-64.org/documentation/abi-0.99.7.pdf
  const dwarf_numbering = Dict{Int, Symbol}(
  0  => :rax,   1  => :rdx,   2  => :rcx, 
  3  => :rbx,   4  => :rsi,   5  => :rdi,
  6  => :rbp,   7  => :rsp,  
  (i => symbol("r$i") for i = 8:15)...,
  16 => :rip,   
  (17+i => symbol("xmm$i") for i = 0:15)...,
  (33+i => symbol("st$i") for i = 0:7)...,
  (41+i => symbol("mm$i") for i = 0:7)...,
  49 => :rflags,
  50 => :es, 51 => :cs, 52 => :ss,
  53 => :ds, 54 => :fs, 55 => :gs,
  58 => symbol("fs.base"), 59 => symbol("gs.base"),
  62 => :tr, 63 => :ldtr, 64 => :mxcsr, 65 => :fcw,
  66 => :fsw)
  const inverse_dwarf = map((k,v)->v=>k, dwarf_numbering)
  
  # Basic Register Set
  const basic_regs = 0:16
  const RegT = RegisterValue{UInt64}
  @eval type BasicRegs <: RegisterSet
      $(Expr(:block, (
        :($(dwarf_numbering[i]) :: RegT) for i in basic_regs
      )...))
  end
  Registers.ip(regs::RegisterSet) = regs.rip
  Registers.set_ip!(reg::RegisterSet, ip) = regs.rip = ip
  Registers.set_sp!(reg::RegisterSet, ip) = regs.rip = sp
  function Registers.invalidate_regs!(regs::BasicRegs)
      for fieldi = 1:nfields(regs)
          setfield(regs, i, Registers.invalidated(getfield(regs, i)))
      end
  end

  function Registers.set_dwarf!(regs::BasicRegs, reg, value)
      (reg < endof(basic_regs)) && (setfield(regs, reg, value))
  end

  function Register.get_dwarf(regs::BasicRegs, reg)
      (reg < endof(basic_regs)) ? getfield(regs, reg) :
        RegisterValue{UInt64}(0, 0)
  end

end
