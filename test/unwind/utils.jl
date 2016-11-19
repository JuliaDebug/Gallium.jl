using ObjFileBase, ELF

ld = "/data/keno/ldtest/usr/bin/ld.bfd"

function build_executable(name, shlibs = String[])
    cd("inputs") do
      run(`llvm-mc -filetype=obj -o $name.o $name.S`)
      run(`$ld -rpath=. -o $name.out $shlibs $name.o`)
    end
end

function build_shlib(name)
    cd("inputs") do
      run(`llvm-mc -filetype=obj -o $name.o $name.S`)
      run(`$ld -shared -o $name.dylib $name.o`)
    end
end

function build_simple_mod_map(fn)
  # Build module map
  base = 0x0000000000400000
  h = readmeta(IOBuffer(open(Base.Mmap.mmap, fn)))
  modules = Dict{RemotePtr{Void},Any}(
     RemotePtr{Void}(base) => Gallium.GlibcDyldModules.mod_for_h(h, base, fn)
  )
  modules, h
end

function one_call_fake_stack(modules, start_offset)
  # Build fake stack
  stacktop = 0x0000000000500000
  (h, base, sym)  = Gallium.lookup_sym(nothing, modules, "_start")
  startaddr = Gallium.compute_symbol_value(h, base, sym)
  stack = reinterpret(UInt8,
    UInt64[
      # Return address pushed by the call
      UInt64(startaddr)+start_offset
    ])
  RC = Gallium.X86_64.BasicRegs()
  sess = Gallium.FakeMemorySession([(stacktop-sizeof(stack), stack)],Gallium.X86_64.X86_64Arch())
  set_dwarf!(RC, :rsp, stacktop - sizeof(stack))
  RC, sess
end

function compute_addr(modules, name)
  (h, base, sym) = Gallium.lookup_sym(nothing, modules, name)
  UInt64(Gallium.compute_symbol_value(h, base, sym))
end

function compute_section_addr(modules, h, name)
  for (base, mod) in Gallium.module_dict(modules)
    if mod.handle == h
      sec = first(filter(sec->sectionname(sec) == name, Sections(h)))
      return UInt64(
        deref(sec).sh_addr + (Gallium.first_executable_segment(ELF.ProgramHeaders(h)).p_vaddr - base))
    end
  end
  error("Not found")
end
