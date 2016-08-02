module Ptrace
  using ..Gallium
  using ..Gallium: RemotePtr, X86_64
  using ..Gallium.Registers: RegisterValue
  using ObjFileBase
  import Base: start, next, done, iteratorsize

  include(joinpath(dirname(@__FILE__),"constants","ptrace.jl"))

  immutable Session
      pid::Cint
      mem_fd::Base.RawFD
  end
  
  immutable MapsIterator
      file::String
  end
  start(x::MapsIterator) = open(x.file)
  function next(x::MapsIterator, file)
      line = readline(file)
      parts = split(line, ' ', keep = false)
      range = UnitRange{UInt64}(parse.([UInt64],split(parts[1],'-'),16)...)
      # Our ranges are [,], kernel ones are [,)
      range = first(range):last(range)-1
      fname = length(parts) == 6 ? strip(parts[6]) : ""
      ((range, fname, line), file)
  end
  done(x::MapsIterator, file) = eof(file)
  iteratorsize(::Type{MapsIterator}) = Base.SizeUnknown()
  
  function waitpid(s::Session)
    status = Ref{Cint}(0)
    rpid = ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint), s.pid, status, 0)
    @assert rpid == s.pid
  end
  
  function ptrace(req, pid, addr, data)
    Libc.errno(0) # Make sure to set errno to 0, so we can detect failure
    res = ccall(:ptrace, Clong, (Cint, Cint, Ptr{Void}, Ptr{Void}),
      req, pid, addr, data)
    Base.systemerror("ptrace", res == -1 && Libc.errno() != 0)
    (res % Culong)
  end

  function Gallium.read_exe(s::Session)
      readmeta(IOBuffer(open(Base.Mmap.mmap, "/proc/$pid/exe")))
  end

  function attach(pid)
    pid = convert(Cint, pid)
    ptrace(PTRACE_ATTACH, pid, C_NULL, C_NULL)
    sess = Session(pid, RawFD(
      ccall(:open, Cint, (Ptr{UInt8}, Cint), "/proc/$pid/mem", Base.JL_O_RDWR)))
    imageh = Gallium.read_exe(sess)
    modules = Gallium.GlibcDyldModules.load_library_map(sess, imageh)
    sess, modules
  end
  
  function Gallium.load{T}(s::Session, ptr::RemotePtr{T})
    r = Ref{T}()
    Base.systemerror("pread(/proc/mem)",
      ccall(:pread, Cssize_t, (Cint, Ptr{Void}, Csize_t, UInt64),
        s.mem_fd, r, sizeof(T), convert(UInt64, ptr)) == -1)
    r[]
  end
  
  function Gallium.load{T}(s::Session, ptr::RemotePtr{T}, count)
    r = Vector{T}(count)
    Base.systemerror("pread(/proc/mem)",
      ccall(:pread, Cssize_t, (Cint, Ptr{Void}, Csize_t, UInt64),
        s.mem_fd, r, sizeof(r), convert(UInt64, ptr)) == -1)
    r
  end
  
  function Gallium.mapped_file(s::Session, ptr::RemotePtr)
    first(filter(map->UInt64(ptr) ∈ map[1], MapsIterator("/proc/$(s.pid)/maps")))[2]
  end
  
  immutable iovec
      iov_base::Ptr{Void}
      iov_len::Csize_t
  end
  
  const NT_PRSTATUS = 1
  function Gallium.getregs(s::Session)
    regs = Array(UInt64, length(X86_64.kernel_order))
    iov = Ref{iovec}(iovec(pointer(regs), sizeof(regs)))
    ptrace(PTRACE_GETREGSET, s.pid, Ptr{Void}(NT_PRSTATUS), iov)
    @assert iov[].iov_len == sizeof(regs)
    rregs = X86_64.BasicRegs()
    for i in X86_64.basic_regs
      setfield!(rregs, i+1,
        RegisterValue{UInt64}(
          regs[X86_64.kernel_numbering[X86_64.dwarf_numbering[i]]]))
    end
    rregs
  end
  
  function Gallium.continue!(s::Session)
    ptrace(PTRACE_CONT, s.pid, C_NULL, C_NULL)
    waitpid(s)
  end
  
  function Gallium.single_step!(s::Session)
    ptrace(PTRACE_SINGLESTEP, s.pid, C_NULL, C_NULL)
    waitpid(s)
  end
  
end
