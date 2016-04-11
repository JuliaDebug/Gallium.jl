module Unwinder

using DWARF
using DWARF.CallFrameInfo
using ObjFileBase
using ObjFileBase: handle
using Gallium
using ..Registers
using ..Registers: ip
using ObjFileBase
using ELF
using Gallium: find_module, Module, load


function get_word(s, ptr::RemotePtr)
    Gallium.Hooking.mem_validate(UInt(ptr), sizeof(Ptr{Void})) || error("Invalid load")
    load(s, RemotePtr{UInt64}(ptr))
end


function find_fde(mod, modrel)
    slide = 0
    eh_frame = first(filter(x->sectionname(x)==".eh_frame",ELF.Sections(handle(mod))))
    if isa(mod, Module) && !isempty(mod.FDETab)
        tab = mod.FDETab
    else
        eh_frame_hdr = first(filter(x->sectionname(x)==".eh_frame_hdr",ELF.Sections(handle(mod))))
        tab = CallFrameInfo.EhFrameRef(eh_frame_hdr, eh_frame)
        modrel = Int(modrel)-Int(sectionoffset(eh_frame_hdr))
        slide = sectionoffset(eh_frame_hdr) - sectionoffset(eh_frame)
    end
    CallFrameInfo.search_fde_offset(eh_frame, tab, modrel, slide)
end

function modulerel(mod, base, ip)
    ret = (ip - base)
end
function frame(s, modules, r)
    base, mod = find_module(modules, UInt(ip(r)))
    modrel = UInt(modulerel(mod, base, UInt(ip(r))))
    fde = find_fde(mod, modrel)
    cie = realize_cie(fde)
    # Compute CFA
    loc = initial_loc(fde, cie)
    target_delta = modrel - loc
    if handle(mod).file.header.e_type == ELF.ET_REL
        eh_frame = first(filter(x->sectionname(x) == ".eh_frame",ELF.Sections(handle(mod))))
        target_delta = UInt(ip(r)) - (loc + deref(eh_frame).sh_addr - sectionoffset(eh_frame))
    end
    @assert target_delta < CallFrameInfo.fde_range(fde, cie)
    # out = IOContext(STDOUT, :reg_map => Gallium.X86_64.dwarf_numbering)
    # drs = CallFrameInfo.RegStates()
    # CallFrameInfo.dump_program(out, cie, target = UInt(target_delta), rs = drs); println(out)
    # CallFrameInfo.dump_program(out, fde, cie = cie, target = UInt(target_delta), rs = drs)
    rs = CallFrameInfo.evaluate_program(fde, UInt(target_delta), cie = cie)
    local cfa_addr
    if isa(rs.cfa, Tuple{CallFrameInfo.RegNum,Int})
        cfa_addr = RemotePtr{Void}(convert(Int, get_dwarf(r, Int(rs.cfa[1])) + rs.cfa[2]))
    elseif isa(rs.cfa, CallFrameInfo.Undef)
        error("CFA may not be undef")
    else
        sm = DWARF.Expressions.StateMachine{typeof(unsigned(ip(r)))}()
        getreg(reg) = get_dwarf(r, reg)
        getword(addr) = get_word(s, addr)[]
        addr_func(addr) = addr
        loc = DWARF.Expressions.evaluate_simple_location(sm, rs.cfa.opcodes, getreg, getword, addr_func, :NativeEndian)
        if isa(loc, DWARF.Expressions.RegisterLocation)
            cfa_addr = get_dwarf(r, loc.i)
        else
            cfa_addr = loc.i
        end
    end
    cfa_addr, rs, cie, UInt(target_delta)
end

function symbolicate(modules, ip)
    base, mod = find_module(modules, ip)
    modrel = UInt(modulerel(mod, base, ip))
    fde = find_fde(mod, modrel)
    cie = realize_cie(fde)
    fbase = initial_loc(fde, cie)
    sections = ELF.Sections(handle(mod))
    if handle(mod).file.header.e_type == ELF.ET_REL
        eh_frame = first(filter(x->sectionname(x) == ".eh_frame",sections))
        fbase += deref(eh_frame).sh_addr - sectionoffset(eh_frame)
    end
    local syms
    secs = collect(filter(x->sectionname(x) == ".symtab",sections))
    isempty(secs) && (secs = collect(filter(x->sectionname(x) == ".dynsym",sections)))
    syms = ELF.Symbols(secs[1])
    idx = findfirst(syms) do x
        value = ELF.symbolvalue(x, sections)
        value == fbase
    end
    idx == 0 && return "???"
    symname(syms[idx]; strtab = ELF.StrTab(syms))
end

function fetch_cfi_value(s, r, resolution, cfa_addr)
    if isa(resolution, CallFrameInfo.Same)
        return get_dwarf(r, reg)
    elseif isa(resolution, CallFrameInfo.Offset)
        if resolution.is_val
            return cfa_addr + resolution.n
        else
            return get_word(s, cfa_addr + (resolution.n % UInt))
        end
    elseif isa(resolution, CallFrameInfo.Expr)
        error("Not implemented")
    elseif isa(resolution, CallFrameInfo.Reg)
        return get_dwarf(r, resolution.n)
    else
        error("Unknown resolution $resolution")
    end
end

function unwind_step(s, modules, r)
    new_registers = copy(r)
    # A priori the registers in the new frame will not be valid, we copy them
    # over from above still and propagate as usual in case somebody wants to
    # look at them.
    invalidate_regs!(new_registers)
    cfa, rs, cie, delta = try
        frame(s, modules, r)
    catch e
        rethrow(e)
        return (false, r)
    end

    # Heuristic: If we're stopped at function entry, the CFA is still in the sp
    # register, but the CFI may be incorrect here. Manually unwind, retaining
    # the registers from this frame.
    #=if delta == 0
        new_registers = copy(r)
        set_ip!(new_registers, fetch_cfi_value(s, r, rs[cie.return_reg], get_sp(r)))
        return new_registers
    end=#
    
    # By definition, the next frame's stack pointer is our CFA
    set_sp!(new_registers, UInt(cfa))
    isa(rs[cie.return_reg], CallFrameInfo.Undef) && return (false, r)
    # Find current frame's return address, (i.e. the new frame's ip)
    set_ip!(new_registers, fetch_cfi_value(s, r, rs[cie.return_reg], cfa))
    # Now set other registers recorded in the CFI
    for (reg, resolution) in rs.values
        reg == cie.return_reg && continue
        set_dwarf!(new_registers, reg, fetch_cfi_value(s, r, resolution, cfa))
    end
    UInt(ip(new_registers)) == 0 &&  return (false, r)
    (true, new_registers)
end

end
