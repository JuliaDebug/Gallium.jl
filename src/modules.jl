using DWARF
using DWARF.CallFrameInfo
using ObjFileBase
using ObjFileBase: handle, isrelocatable, Sections, mangle_sname

"""
Keeps a list of local modules, lazy loading those that it doesn't have from
the current process's address space.
"""
immutable Module
    handle::Any
    # If the object containing this module's DWARF info is different,
    # this is the handle to it
    dwarfhandle::Any
    FDETab::Vector{Tuple{Int,UInt}}
end
ObjFileBase.handle(mod::Module) = mod.handle
dhandle(mod::Module) = mod.dwarfhandle
dhandle(h) = h
type LazyLocalModules
    modules::Dict{UInt, Module}
    nsharedlibs::Int
end
LazyLocalModules() = LazyLocalModules(Dict{UInt, Any}(), 0)

function first_actual_segment(h)
    deref(first(filter(x->isa(deref(x),MachO.segment_commands)&&(segname(x)!="__PAGEZERO"), LoadCmds(handle(h)))))
end

function _find_module(modules, ip)
    for (base, h) in modules
        (base, ip) = (UInt(base), UInt(ip))
        # TODO: cache this
        local sz
        if isrelocatable(handle(h))
            sz = sectionsize(first(filter(x->sectionname(x) == mangle_sname(handle(h),"text"), Sections(handle(h)))))
        elseif isa(handle(h), ELF.ELFHandle)
            phs = ELF.ProgramHeaders(handle(h))
            sz = first(filter(x->x.p_type == ELF.PT_LOAD, phs)).p_memsz
        elseif isa(handle(h), MachO.MachOHandle)
            sz = first_actual_segment(h).vmsize
        end
        if base <= ip <= base + sz
            return (base, h)
        end
    end
    nothing
end

function find_module(modules, ip)
    ret = _find_module(modules, ip)
    (ret == nothing) && error("ip 0x$(hex(UInt(ip),2sizeof(UInt))) found")
    ret
end

"""
base is the remote address of the text section
"""
function make_fdetab(base, mod)
    FDETab = Vector{Tuple{Int,UInt}}()
    eh_frame = find_ehframes(mod)[]
    for fde in FDEIterator(eh_frame)
        # Make this location, relative to base. Note that base means something different,
        # depending on whether we're isrelocatable or not. If we are, base is the load address
        # of the text section. Otherwise, base is the load address of the start of the mapping.
        if isa(mod, ELF.ELFHandle)
            # For relocated ELF Objects and unlrelocated shared libraries,
            # it is an offset from the load address of the FDE (in the shared library case,
            # sh_addr == sectionoffset).
            ip = (deref(eh_frame).sh_addr - sectionoffset(eh_frame) + initial_loc(fde)) - base
        elseif isrelocatable(mod)
            # MachO eh_frame section doesn't get relocated, so it's still relative to
            # the file's local address space.
            text = first(filter(x->sectionname(x)==mangle_sname(mod,"text"),Sections(mod)))
            ip = initial_loc(fde) - sectionoffset(text)
        else
            ip = initial_loc(fde)
        end
        push!(FDETab,(ip, fde.offset))
    end
    sort!(FDETab, by=x->x[1])
    FDETab
end

function obtain_uuid(h)
    deref(first(filter(x->isa(deref(x),MachO.uuid_command), LoadCmds(h)))).uuid
end

@osx_only function obtain_dsym(fname, objecth)
    dsympath = string(fname, ".dSYM/Contents/Resources/DWARF/", basename(fname))
    isfile(dsympath) || return objecth
    debugh = readmeta(IOBuffer(open(read, dsympath)))
    (obtain_uuid(objecth) != obtain_uuid(debugh)) && return debugh
    debugh
end

find_ehframes(sects::ObjFileBase.Sections) = collect(filter(x->sectionname(x)==mangle_sname(handle(sects),"eh_frame"),sects))
find_ehframes(h::ELF.ELFHandle) = find_ehframes(Sections(h))
function find_ehframes(h::MachO.MachOHandle)
    mapreduce(x->find_ehframes(Sections(x)), vcat,
        filter(x->isa(deref(x), MachO.segment_commands), LoadCmds(h)))
end

@osx_only function update_shlibs!(modules)
    nactuallibs = ccall(:_dyld_image_count, UInt32, ())
    if modules.nsharedlibs != nactuallibs
        for idx in (modules.nsharedlibs+1):nactuallibs
            idx -= 1
            base = ccall(:_dyld_get_image_vmaddr_slide, UInt, (UInt32,), idx)
            fname = bytestring(
                ccall(:_dyld_get_image_name, Ptr{UInt8}, (UInt32,), idx))
            # hooking is weird
            contains(fname, "hooking.dylib") &&
                continue
            h = readmeta(IOBuffer(open(read, fname)))
            if isa(h, MachO.FatMachOHandle)
                h = h[findfirst(arch->arch.cputype == MachO.CPU_TYPE_X86_64, h.archs)]
            end
            # Do not record the dynamic linker in our module list
            # Also skip the executable for now
            ft = readheader(h).filetype
            if ft == MachO.MH_DYLINKER
                continue
            end
            # For now, don't record shared libraries for which we only
            # have compact unwind info.
            ehfs = find_ehframes(h)
            length(collect(ehfs)) == 0 && continue
            fdetab = make_fdetab(base, h)
            vmaddr = first_actual_segment(h).vmaddr
            base += vmaddr
            modules.modules[base] = Module(h, obtain_dsym(fname, h), fdetab)
        end
        modules.nsharedlibs = nactuallibs
        return true
    end
    return false
end


@linux_only function update_shlibs!(modules)
    return false
end

function find_module(modules::LazyLocalModules, ip)
    ret = _find_module(modules.modules, ip)
    if ret == nothing
        if update_shlibs!(modules)
            return find_module(modules, ip)
        end
        data = ccall(:jl_get_dobj_data, Any, (UInt,), ip)
        @assert data != nothing
        buf = IOBuffer(copy(data), true, true)
        h = readmeta(buf)
        sstart = ccall(:jl_get_section_start, UInt64, (UInt,), ip-1)
        fdetab = Vector{Tuple{Int,UInt}}()
        if isrelocatable(h)
          isa(h, ELF.ELFHandle) && ELF.relocate!(buf, h)
          fdetab = make_fdetab(sstart, h)
          if isa(h, MachO.MachOHandle)
            LOI = Dict(:__text => sstart,
                :__debug_str=>0) #This one really shouldn't be necessary
            MachO.relocate!(buf, h; LOI=LOI)
          end
        end
        isa(h, MachO.MachOHandle) && isempty(fdetab) && (fdetab = make_fdetab(sstart, h))
        modules.modules[sstart] = Module(h, h, fdetab)
        ret = (sstart, modules.modules[sstart])
    end
    ret
end

function lookup_sym(modules, name)
    name = string(name)
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
    error("Not found")
end


"""
Load the set of active modules from the GlibC dynamic linker
"""
module GlibcDyldModules
  using ELF
  using Gallium
  using ObjFileBase
  using Gallium: load, mapped_file

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
    entry_idx = findfirst(i->auxv[i] == ELF.AT_ENTRY, 1:2:length(auxv))
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
  function load_library_map(vm, imageh, image_slide = 0)
    # Step 1: Obtain the target address space's r_debug struct
    dynamic_sec = first(filter(x->sectionname(x)==".dynamic",ELF.Sections(imageh)))
    dynamic = reinterpret(UInt64,read(dynamic_sec))
    dt_debug_idx = findfirst(i->dynamic[i]==ELF.DT_DEBUG, 1:2:length(dynamic))

    dynamic_load_addr = deref(dynamic_sec).sh_addr + image_slide

    dt_debug_addr_addr = RemotePtr{UInt64}(dynamic_load_addr + (2*dt_debug_idx-1)*sizeof(Ptr{Void}))
    dt_debug_addr = RemotePtr{r_debug}(load(vm, dt_debug_addr_addr))

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
            buf = IOBuffer(open(read, mapped_file(vm, lm.l_addr)))
            modules[lm.l_addr] = readmeta(buf)
        end
        lm = load(vm, lm.l_next)
    end

    modules
  end

end
