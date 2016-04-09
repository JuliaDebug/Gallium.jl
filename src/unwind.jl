module Unwinder

using CallFrameInfo
using ..Registers
using ..Registers: ip
using ObjFileBase
using ELF
using DWARF

function get_word
end

function find_module(modules, ip)
    for (base, h) in modules
        (base, ip) = (UInt(base), UInt(ip))
        if base <= ip <= base + filesize(h.io)
            return (base, h)
        end
    end
    error("Not found")
end

function find_fde(mod, modrel)
    eh_frame_hdr = first(filter(x->sectionname(x)==".eh_frame_hdr",ELF.Sections(mod)))
    eh_frame = first(filter(x->sectionname(x)==".eh_frame",ELF.Sections(mod)))
    hdrref = CallFrameInfo.EhFrameRef(eh_frame_hdr, eh_frame)
    CallFrameInfo.search_fde_offset(hdrref, Int(modrel)-Int(sectionoffset(eh_frame_hdr)))
end

modulerel(mod, base, ip) = ip - base
function frame(s, modules, r)
    base, mod = find_module(modules, ip(r))
    modrel = UInt(modulerel(mod, base, ip(r)))
    fde = find_fde(mod, modrel)
    cie = realize_cie(fde)
    # Compute CFA
    target_delta = modrel - initial_loc(fde, cie)
    # out = IOContext(STDOUT, :reg_map => Main.X86_64.dwarf_numbering)
    # CallFrameInfo.dump_program(out, cie); println(out)
    # CallFrameInfo.dump_program(out, fde, cie = cie)
    rs = CallFrameInfo.evaluate_program(fde, UInt(target_delta), cie = cie)
    local cfa_addr
    if isa(rs.cfa, Tuple{CallFrameInfo.RegNum,Int})
        cfa_addr = convert(Int, get_dwarf(r, Int(rs.cfa[1])) + rs.cfa[2])
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
    local syms
    sections = ELF.Sections(mod)
    secs = collect(filter(x->sectionname(x) == ".symtab",sections))
    isempty(secs) && (secs = collect(filter(x->sectionname(x) == ".dynsym",sections)))
    syms = ELF.Symbols(secs[1])
    idx = findfirst(syms) do x
        value = deref(x).st_value
        shndx = deref(x).st_shndx
        if shndx != ELF.SHN_UNDEF && shndx < ELF.SHN_LORESERVE
            sec = sections[shndx]
            value += deref(sec).sh_addr - sectionoffset(sec)
        end
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
    catch
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
    set_sp!(new_registers, cfa)
    isa(rs[cie.return_reg], CallFrameInfo.Undef) && return (false, r)
    # Find current frame's return address, (i.e. the new frame's ip)
    set_ip!(new_registers, fetch_cfi_value(s, r, rs[cie.return_reg], cfa))
    # Now set other registers recorded in the CFI
    for (reg, resolution) in rs.values
        reg == cie.return_reg && continue
        set_dwarf!(new_registers, reg, fetch_cfi_value(s, r, resolution, cfa))
    end
    (true, new_registers)
end

end
