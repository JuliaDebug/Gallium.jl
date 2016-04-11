using DWARF
using DWARF.CallFrameInfo
using ObjFileBase
using ObjFileBase: handle

"""
Keeps a list of local modules, lazy loading those that it doesn't have from
the current process's address space.
"""
immutable Module
    handle::Any
    FDETab::Vector{Tuple{Int,UInt}}
end
ObjFileBase.handle(mod::Module) = mod.handle
immutable LazyLocalModules
    modules::Dict{UInt, Module}
end
LazyLocalModules() = LazyLocalModules(Dict{UInt, Any}())

function _find_module(modules, ip)
    for (base, h) in modules
        (base, ip) = (UInt(base), UInt(ip))
        # TODO: cache this
        local sz
        if handle(h).file.header.e_type == ELF.ET_REL
            sz = sectionsize(first(filter(x->sectionname(x) == ".text", ELF.Sections(handle(h)))))
        else
            phs = ELF.ProgramHeaders(handle(h))
            sz = first(filter(x->x.p_type == ELF.PT_LOAD, phs)).p_memsz
        end
        if base <= ip <= base + sz
            return (base, h)
        end
    end
    nothing
end

function find_module(modules, ip)
    ret = _find_module(modules, ip)
    (ret == nothing) && error("Not found")
    ret
end

"""
base is the remote address of the text section
"""
function make_fdetab(base, mod)
    FDETab = Vector{Tuple{Int,UInt}}()
    eh_frame = first(filter(x->sectionname(x)==".eh_frame",ELF.Sections(mod)))
    for fde in FDEIterator(eh_frame)
        # Make this location, relative to base. A priori, it is an offset from 
        # the load address of the FDE.
        ip = (deref(eh_frame).sh_addr - sectionoffset(eh_frame) + initial_loc(fde)) - base
        push!(FDETab,(ip, fde.offset))
    end
    sort!(FDETab, by=x->x[1])
    FDETab
end

function find_module(modules::LazyLocalModules, ip)
    ret = _find_module(modules.modules, ip)
    if ret == nothing
        buf = IOBuffer(copy(ccall(:jl_get_dobj_data, Any, (UInt,), ip)), true, true)
        h = readmeta(buf)
        sstart = ccall(:jl_get_section_start, UInt64, (UInt,), ip-1)
        fdetab = Vector{Tuple{Int,UInt}}()
        if isa(h, ELF.ELFHandle)
          if h.file.header.e_type == ELF.ET_REL
              ELF.relocate!(buf, h)
              fdetab = make_fdetab(sstart, h)
          end
        else
          LOI = Dict(:__text => sstart,
              :__debug_str=>0) #This one really shouldn't be necessary
          MachO.relocate!(buf, h; LOI=LOI)
        end
        modules.modules[sstart] = Module(h, fdetab)
        ret = (sstart, modules.modules[sstart])
    end
    ret
end

function lookup_sym(modules, name)
  for (base, h) in modules
      symtab = ELF.Symbols(h)
      strtab = StrTab(symtab)
      idx = findfirst(x->ELF.symname(x, strtab = strtab)==name,symtab)
      if idx != 0
          sym = symtab[idx]
          if ELF.isundef(sym)
              continue
          end
          return (h, base, sym)
      end
  end  
end


"""
Load the set of active modules from the GlibC dynamic linker
"""
module GlibcDyldModules
  using ELF
  using Gallium

  immutable link_map
    l_addr::RemotePtr{Void}
    l_name::RemotePtr{UInt8}
    l_ld::RemotePtr{Void}
    l_next::RemotePtr{link_map}
    l_prev::RemotePtr{link_map}
  end

  immutable r_debug
    r_version::Cint
    link_map::RemotePtr{link_map}
    r_brk::UInt64
    r_state::Cint
    r_ldbase::RemotePtr{Void}
  end
  
  """
    Computes the object's entry point from the kernel's auxv data. By comparing
    this information to the specified entrypoint in the executable image, one
    can compute the slide of the executable image in memory.
  """
  function compute_entry_ptr(auxv_data::Vector{UInt8})
    auxv = reinterpret(UInt64, auxv_data)
    entry_idx = findfirst(i->auxv2[i] == ELF.AT_ENTRY, 1:2:length(auxv2))
    @assert entry_idx != 0
    #  auxv_idx = 1+2(entry_idx-1), we want auxv_idx + 1 == entry_idx
    entry_ptr = auxv[2entry_idx]
  end
  
  """
    Load the shared library map from address space `vm`.
    `imageh` should be the ObjectHandle of the main executable and `auxv_data`
    should be the session's auxv buffer.
    
    If the executable was not loaded at it's defined virtual address, you
    may set `image_slide` to the offset of the executable's load address from
    it's intended load address.
  """
  function load_library_map(vm, imageh; image_slide = 0)
    
    # Step 1: Obtain the target address space's r_debug struct
    dynamic_sec = first(filter(x->sectionname(x)==".dynamic",ELF.Sections(imageh)))
    dynamic = reinterpret(UInt64,read(dynamic_sec))
    dt_debug_idx = findfirst(i->dynamic[i]==ELF.DT_DEBUG, 1:2:length(dynamic))

    dynamic_load_addr = deref(dynamic_sec).sh_addr + image_slide

    dt_debug_addr_addr = RemotePtr{UInt64}(dynamic_load_addr + (2*dt_debug_idx-1)*sizeof(Ptr{Void}))
    dt_debug_addr = RemotePtr{r_debug}(RR.load(RR.current_task(session), dt_debug_addr_addr))

    debug_struct = load(vm, dt_debug_addr)
    last_link_map = load(vm, debug_struct.link_map)

    # Step 2: Construct the actual module map
    modules = Dict{RemotePtr{Void},Any}()

    # First the main executable. To do so we need to find the image base.
    phs = ELF.ProgramHeaders(imageh)
    idx = findfirst(p->p.p_offset==0&&p.p_type==ELF.PT_LOAD, phs)
    imagebase = phs[idx].p_vaddr + image_slide
    modules[RemotePtr{Void}(imagebase)] = imageh

    # Now for the shared libraries. We traverse the linked list of modules
    # in the dynamic linker's r_debug structure.
    lm = last_link_map
    while lm.l_next.ptr != 0
        # Do not add to the module list if the name is empty. This is true for
        # the main executable as well as the dynamic library loader
        if load(vm, lm.l_name) != 0
            # Don't use the IOStream directly. We do a look of seeking/poking,
            # so loading the whole thing into memory and using an IOBuffer is
            # faster
            buf = IOBuffer(open(read, RR.mapped_file(RR.current_task(session), lm.l_addr)))
            modules[lm.l_addr] = readmeta(buf)
        end
        lm = load(vm, lm.l_next)
    end
    
    modules
  end

end
