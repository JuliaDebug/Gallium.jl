using DWARF
using DWARF.CallFrameInfo
using DWARF.CallFrameInfo: EhFrameRef, CIECache
using ObjFileBase
using ObjFileBase: handle, isrelocatable, Sections, mangle_sname


"""
Keeps a list of local modules, lazy loading those that it doesn't have from
the current process's address space.
"""
immutable Module{T<:ObjFileBase.ObjectHandle, SR<:ObjFileBase.SectionRef}
    handle::T
    # The .eh_frame section when unwinding using DWARF
    eh_frame::Nullable{SR}
    # Either a DWARF or SEH header/unwind table pair
    ehfr::Nullable{EhFrameRef}
    xpdata::Nullable{XPUnwindRef}
    # If the object containing this module's DWARF info is different,
    # this is the handle to it
    dwarfhandle::T
    # Keeps symbol table indices in ip order as opposed to alphabetically,
    # to accelerate symbol lookup by ip.
    inverse_symtab::Vector{UInt32}
    FDETab::Vector{Tuple{Int,UInt}}
    ciecache::CIECache
    sz::UInt
end
Module(handle, eh_frame, eh_frame_hdr, dwarfhandle, FDETab, ciecache, sz) =
    Module{typeof(handle),typeof(eh_frame)}(handle, eh_frame, eh_frame_hdr,
        Nullable{XPUnwindRef}(), dwarfhandle, FDETab, ciecache, sz)

ObjFileBase.handle(mod::Module) = mod.handle
dhandle(mod::Module) = mod.dwarfhandle
dhandle(h) = h
type LazyJITModules
    session
    modules::Dict{UInt, Module}
    nsharedlibs::Int
end
LazyJITModules() = LazyJITModules(LocalSession(), Dict{UInt, Any}(), 0)

function first_actual_segment(h)
    deref(first(filter(x->isa(deref(x),MachO.segment_commands)&&(segname(x)!="__PAGEZERO"), LoadCmds(handle(h)))))
end

function get_syms(mod)
    local syms
    h = dhandle(mod)
    sections = Sections(h)
    if isa(h, ELF.ELFHandle)
        secs = collect(filter(x->sectionname(x) == ".symtab",sections))
        isempty(secs) && (secs = collect(filter(x->sectionname(x) == ".dynsym",sections)))
        syms = ELF.Symbols(secs[1])
    elseif isa(h, MachO.MachOHandle)
        syms = MachO.Symbols(h)
    elseif isa(h, COFF.COFFHandle)
        syms = COFF.Symbols(h)
    end
    syms
end

function make_inverse_symtab(h)
    sects = Sections(h)
    UInt32[symbolnum(x) for x in sort!(collect(get_syms(h)), by = x->symbolvalue(x,sects))]
end

function compute_mod_size(h)
    if isrelocatable(handle(h))
        sz = sectionsize(first(filter(x->sectionname(x) == mangle_sname(handle(h),"text"), Sections(handle(h)))))
    elseif isa(handle(h), ELF.ELFHandle)
        phs = ELF.ProgramHeaders(handle(h))
        sz = first(filter(x->x.p_type == ELF.PT_LOAD, phs)).p_memsz
    elseif isa(handle(h), MachO.MachOHandle)
        sz = first_actual_segment(h).vmsize
    elseif isa(handle(h), COFF.COFFHandle)
        sz = COFF.readoptheader(handle(h)).standard.SizeOfCode
    end
    UInt(sz)
end
compute_mod_size(m::Module) = UInt(m.sz)

@inline function _find_module(modules, theip)
    ip = UInt(theip)
    for (mbase, h) in modules
        base = UInt(mbase)
        sz = compute_mod_size(h)::UInt
        if base <= ip <= base + sz
            return Nullable{Pair{UInt,Any}}(Pair{UInt,Any}(base,h))
        end
    end
    Nullable{Pair{UInt,Any}}()
end

function find_module(modules, ip)
    ret = _find_module(modules, ip)
    isnull(ret) && error("ip 0x$(hex(UInt(ip),2sizeof(UInt))) found")
    get(ret)
end

"""
base is the remote address of the text section
"""
function make_fdetab(base, mod, is_eh_not_debug=true)
    FDETab = Vector{Tuple{Int,UInt}}()
    eh_frame = find_ehframes(mod)[]
    for fde in FDEIterator(eh_frame,is_eh_not_debug)
        # Make this location, relative to base. Note that base means something different,
        # depending on whether we're isrelocatable or not. If we are, base is the load address
        # of the text section. Otherwise, base is the load address of the start of the mapping.
        if isa(mod, ELF.ELFHandle)
            # For relocated ELF Objects and unlrelocated shared libraries,
            # it is an offset from the load address of the FDE (in the shared library case,
            # sh_addr == sectionoffset).
            ip = (Int(deref(eh_frame).sh_addr) - Int(sectionoffset(eh_frame)) + Int(initial_loc(fde))) - Int(base)
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

@static if is_apple()
    function obtain_dsym(fname, objecth)
        dsympath = string(fname, ".dSYM/Contents/Resources/DWARF/", basename(fname))
        isfile(dsympath) || return objecth
        debugh = readmeta(IOBuffer(open(read, dsympath)))
        (obtain_uuid(objecth) != obtain_uuid(debugh)) && return debugh
        debugh
    end
end

find_ehframes{T<:Union{ELF.ELFHandle,MachO.MachOHandle}}(sects::ObjFileBase.Sections{T}) =
    collect(filter(x->sectionname(x)==mangle_sname(handle(sects),"eh_frame"),sects))
find_ehframes{T<:COFF.COFFHandle}(sects::ObjFileBase.Sections{T}) = collect(filter(x->sectionname(x)==mangle_sname(handle(sects),"debug_frame"),sects))
find_ehframes(h::ObjFileBase.ObjectHandle) = find_ehframes(Sections(h))
function find_ehframes(h::MachO.MachOHandle)
    mapreduce(x->find_ehframes(Sections(x)), vcat,
        filter(x->isa(deref(x), MachO.segment_commands), LoadCmds(h)))
end
function find_ehframes{T}(m::Module{T})
    (get(m.eh_frame)::SectionRef(T),)
end
function find_eh_frame_hdr(h)
    first(filter(x->sectionname(x)==mangle_sname(handle(h),"eh_frame_hdr"),Sections(handle(h))))
end
find_eh_frame_hdr{T}(m::Module{T}) = (get(mod.ehfr).hdr_sec)::SectionRef(T)

find_ehfr(mod::Module) = get(mod.ehfr)
find_ehfr(h) = EhFrameRef(find_eh_frame_hdr(h), find_ehframes(h)[1])

@static if is_apple()
    function update_shlibs!(modules)
        nactuallibs = ccall(:_dyld_image_count, UInt32, ())
        if modules.nsharedlibs != nactuallibs
            for idx in (modules.nsharedlibs+1):nactuallibs
                idx -= 1
                base = ccall(:_dyld_get_image_vmaddr_slide, UInt, (UInt32,), idx)
                fname = unsafe_string(
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
                modules.modules[base] = Module(h, Nullable(ehfs[]),
                    Nullable{EhFrameRef}(),
                    Nullable{XPUnwindRef}(),
                    obtain_dsym(fname, h), make_inverse_symtab(h),
                    fdetab, CallFrameInfo.precompute(ehfs[]),
                    compute_mod_size(h))
            end
            modules.nsharedlibs = nactuallibs
            return true
        end
        return false
    end
elseif is_windows()
    function update_shlibs!(modules)
        return false
    end
elseif is_linux()
    function update_shlibs!(modules)
        return false
    end
end

function jit_mod_for_h(buf, h, sstart)
    fdetab = Vector{Tuple{Int,UInt}}()
    ehfr = Nullable{EhFrameRef}()
    xpdata = Nullable{XPUnwindRef}()
    ciecache = CIECache()
    if isrelocatable(h)
      isa(h, ELF.ELFHandle) && ELF.relocate!(buf, h)
      fdetab = make_fdetab(sstart, h)
      if isa(h, MachO.MachOHandle)
        LOI = Dict(:__text => sstart,
            :__debug_str=>0) #This one really shouldn't be necessary
        MachO.relocate!(buf, h; LOI=LOI)
      end
    elseif isa(h, ELF.ELFHandle)
        ehfr = Nullable{EhFrameRef}(find_ehfr(h))
    elseif isa(h, COFF.COFFHandle)
        sects = Sections(h)
        pdata = collect(filter(x->sectionname(x)==ObjFileBase.mangle_sname(h,"pdata"),sects))[]
        xdata = collect(filter(x->sectionname(x)==ObjFileBase.mangle_sname(h,"xdata"),sects))[]
        xpdata = Nullable{XPUnwindRef}(XPUnwindRef(xdata, pdata))
    end
    isa(h, MachO.MachOHandle) && isempty(fdetab) && (fdetab = make_fdetab(sstart, h))
    eh_frame = find_ehframes(h)[]
    !isa(h, COFF.COFFHandle) && (ciecache = CallFrameInfo.precompute(eh_frame))
    Module(h, Nullable(eh_frame),
        ehfr, xpdata, h, make_inverse_symtab(h),
        fdetab, ciecache, compute_mod_size(h))
end

function retrieve_obj_data(s::LocalSession, ip)
    data = ccall(:jl_get_dobj_data, Any, (UInt,), ip)
    @assert data != nothing
    copy(data)
end
retrieve_section_start(s::LocalSession, ip) =
    ccall(:jl_get_section_start, UInt64, (UInt,), ip)

function find_module(modules::LazyJITModules, ip)
    ret = _find_module(modules.modules, ip)
    return !isnull(ret) ? get(ret) : begin
        if update_shlibs!(modules)
            return find_module(modules, ip)
        end
        buf = IOBuffer(retrieve_obj_data(modules.session, ip), true, true)
        h = readmeta(buf)
        sstart = retrieve_section_start(modules.session, ip-1)
        modules.modules[sstart] = jit_mod_for_h(buf, h, sstart)
        Pair{UInt,Any}(sstart, modules.modules[sstart])
    end
end

module_dict(modules) = modules
module_dict(modules::LazyJITModules) = modules.modules

function lookup_sym(modules, name)
    ret = lookup_syms(modules, name)
    length(ret) == 0 && error("Not found")
    ret[]
end

function lookup_syms(modules, name, n = typemax(UInt))
    ret = Any[]
    name = string(name)
    for (base, h) in module_dict(modules)
      symtab = ELF.Symbols(handle(h))
      strtab = StrTab(symtab)
      idx = findfirst(x->ELF.symname(x, strtab = strtab)==name,symtab)
      if idx != 0
          sym = symtab[idx]
          if ELF.isundef(sym)
              continue
          end
          push!(ret,(h, base, sym))
          length(ret) >= n && return ret
      end
    end
    ret
end

"""
Load the set of active modules from the GlibC dynamic linker
"""
module GlibcDyldModules
  using ELF
  using Gallium
  using ObjFileBase
  using Gallium: load, mapped_file, XPUnwindRef
  using DWARF.CallFrameInfo
  using DWARF.CallFrameInfo: EhFrameRef
  using ObjFileBase: mangle_sname, handle

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

  using CRC
  const crc32 = crc(CRC_32)

  """
    Try to obtain a handle to this object's debug object (a second object that
    contains the separated-out debug information). This is done by searching
    following any .gnu_debuglink section that this object may contain.

    References:
    https://access.redhat.com/documentation/en-US/Red_Hat_Enterprise_Linux/4/html/Debugging_with_gdb/separate-debug-files.html
    https://blogs.oracle.com/dbx/entry/gnu_debuglink_or_debugging_system
  """
  function search_debug_object(h, filename)
      sects = Sections(h)
      debuglinks = collect(filter(x->sectionname(x)==mangle_sname(handle(sects),"gnu_debuglink"),sects))
      isempty(debuglinks) && return h
      debuglink = debuglinks[]
      # Read the null terminated name of the debug library
      seek(debuglink, 0)
      fname = readuntil(handle(debuglink), '\0')[1:end-1]
      # Align to 4 byte boundary
      skip(handle(debuglink), ((4-position(debuglink)%4)%4))
      # Read checksum
      crc = read(debuglink, UInt32)
      # Now search for this file in the same locations as GDB
      execdir = dirname(filename)
      const globaldir = "/usr/lib/debug"
      for path in [execdir, joinpath(execdir,".debug"),
                   # For /usr/lib/..., /usr/lib/debug/usr/lib/...
                   joinpath(globaldir, execdir[2:end])]
         fp = joinpath(path, fname)
         isfile(fp) || continue
         buf = open(read, fp)
         crc == crc32(buf) || continue
         return readmeta(IOBuffer(buf))
      end
      return h
  end

  function mod_for_h(h, filename)
      eh_frame = Gallium.find_ehframes(h)[]
      eh_frame_hdr = Gallium.find_eh_frame_hdr(h)
      dh = search_debug_object(h, filename)
      Gallium.Module(h, Nullable(eh_frame),
        Nullable{EhFrameRef}(EhFrameRef(eh_frame_hdr, eh_frame)),
        Nullable{XPUnwindRef}(), dh,
        Gallium.make_inverse_symtab(dh),
        Vector{Tuple{Int,UInt}}(),
        CallFrameInfo.precompute(eh_frame),
        Gallium.compute_mod_size(h))
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
    modules[RemotePtr{Void}(imagebase)] = mod_for_h(imageh, "")

    # Now for the shared libraries. We traverse the linked list of modules
    # in the dynamic linker's r_debug structure.
    lm = last_link_map
    while lm.l_next.ptr != 0
        # Do not add to the module list if the name is empty. This is true for
        # the main executable as well as the dynamic library loader
        if load(vm, lm.l_name) != 0
            # name = load(vm, lm.l_name, 255)
            # idx = findfirst(name,0)
            # idx == 0 ? length(name) : idx
            # @show String(name[1:idx])
            # @show lm.l_addr
            # Some libraries (e.g. wine's fake windows libraries) show up with
            # load address 0, ignore them
            if lm.l_addr != 0
                fn = mapped_file(vm, lm.l_addr)
                if !isempty(fn)
                    # Don't use the IOStream directly. We do a look of seeking/poking,
                    # so loading the whole thing into memory and using an IOBuffer is
                    # faster
                    buf = IOBuffer(open(read, fn))
                    h = readmeta(buf)
                    modules[lm.l_addr] = mod_for_h(h, fn)
                end
            end
        end
        lm = load(vm, lm.l_next)
    end

    modules
  end

end

"""
Load the set of active modules from the Win64 dynamic linker
"""
module Win64DyldModules
    using COFF
    using ELF
    using Gallium
    using ObjFileBase
    using Gallium: load, mapped_file, make_fdetab, XPUnwindRef
    using DWARF.CallFrameInfo
    using DWARF.CallFrameInfo: EhFrameRef, CIECache
    using ..GlibcDyldModules
    import Base: start, next, done

    function get_peb_addr
    end

    # See https://msdn.microsoft.com/en-us/library/windows/desktop/aa380518(v=vs.85).aspx
    immutable UNICODE_STRING
        Length::UInt16
        MaximumLength::UInt16
        Buffer::Ptr{UInt16}
    end

    # See https://msdn.microsoft.com/en-us/library/windows/desktop/aa813706(v=vs.85).aspx
    immutable LDR_DATA_TABLE_ENTRY
        Reserved::NTuple{2,RemotePtr{Void}}
        Prev::RemotePtr{LDR_DATA_TABLE_ENTRY}
        Next::RemotePtr{LDR_DATA_TABLE_ENTRY}
        Reserved2::NTuple{2,RemotePtr{Void}}
        DllBase::RemotePtr{Void}
        EntryPoint::RemotePtr{Void}
        Reserved3::RemotePtr{Void}
        FullDllName::UNICODE_STRING
    end

    immutable ModuleIterator
        vm
        head::RemotePtr{LDR_DATA_TABLE_ENTRY}
    end

    function mod_for_h(dllbase, h)
        sects = Sections(h)
        pdata = collect(filter(x->sectionname(x)==ObjFileBase.mangle_sname(h,"pdata"),sects))[]
        xdata = collect(filter(x->sectionname(x)==ObjFileBase.mangle_sname(h,"xdata"),sects))[]
        Gallium.Module(h, Nullable{typeof(pdata)}(), Nullable{EhFrameRef}(),
            Nullable{XPUnwindRef}(XPUnwindRef(xdata, pdata)), h,
            Gallium.make_inverse_symtab(h),
            Vector{Tuple{Int,UInt}}(),
            CIECache(), Gallium.compute_mod_size(h))
    end

    const PEB_LDR_DATA_OFFSET      = 3 * sizeof(UInt64)
    const InMemoryOrderList_OFFSET = 4 * sizeof(UInt64)
    function ModuleIterator(vm)
        addr = get_peb_addr(vm)
        peb_ldr_data_addr = load(vm, RemotePtr{UInt64}(addr + PEB_LDR_DATA_OFFSET))
        head = peb_ldr_data_addr + InMemoryOrderList_OFFSET
        ModuleIterator(vm, RemotePtr{LDR_DATA_TABLE_ENTRY}(head))
    end

    start(m::ModuleIterator) = load(m.vm, RemotePtr{RemotePtr{LDR_DATA_TABLE_ENTRY}}(m.head))
    function next(m::ModuleIterator, s::RemotePtr{LDR_DATA_TABLE_ENTRY})
        @show s
        entry = load(m.vm, s-16)
        (entry, entry.Prev)
    end
    done(m::ModuleIterator, s::RemotePtr{LDR_DATA_TABLE_ENTRY}) =
        s == m.head || s == 0
    Base.iteratorsize(::Type{ModuleIterator}) = Base.SizeUnknown()

    function load_library_map(vm)
        modules = Dict{RemotePtr{Void},Any}()
        map(ModuleIterator(vm)) do entry
            entry.DllBase == 0 && return
            @show entry.DllBase
            # If this is a Wine library, the first 0x1000 are dynamically
            # allocated to create space for the COFF header. Also try to
            # look 0x1000 bytes after to make sure to get the right file.
            fn = mapped_file(vm, entry.DllBase)
            isempty(fn) && (fn = mapped_file(vm, entry.DllBase + 0x1000))
            if !isempty(fn)
                h = readmeta(IOBuffer(open(read, fn)))
                # If this is an ELF library, it is likely one of wine's internal
                # fake DLLs, follow the Linux codepath instead
                if isa(h, ELF.ELFHandle)
                    modules[entry.DllBase-0x20000] =
                        GlibcDyldModules.mod_for_h(h, fn)
                else
                    modules[entry.DllBase] = mod_for_h(entry.DllBase, h)
                end
            end
        end
        modules
    end
end
