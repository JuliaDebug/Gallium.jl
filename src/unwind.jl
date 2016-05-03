module Unwinder

using DWARF
using DWARF.CallFrameInfo
import DWARF.CallFrameInfo: realize_cie
using ObjFileBase
using ObjFileBase: handle
using Gallium
using ..Registers
using ..Registers: ip
using ObjFileBase
using ObjFileBase: Sections, mangle_sname
using ELF
using MachO
using Gallium: find_module, Module, load


function get_word(s::Gallium.LocalSession, ptr::RemotePtr)
    Gallium.Hooking.mem_validate(UInt(ptr), sizeof(Ptr{Void})) || error("Invalid load")
    load(s, RemotePtr{UInt64}(ptr))
end
get_word(s, ptr::RemotePtr) = load(s, RemotePtr{UInt64}(ptr))

function find_fde(mod, modrel)
    slide = 0
    eh_frame = Gallium.find_ehframes(mod)[1]
    if isa(mod, Module) && isnull(mod.ehfr)
        return CallFrameInfo.search_fde_offset(eh_frame, mod.FDETab, modrel, slide)
    else
        tab = Gallium.find_ehfr(mod)
        modrel = Int(modrel)-Int(sectionoffset(tab.hdr_sec))
        slide = sectionoffset(tab.hdr_sec) - sectionoffset(eh_frame)
        loc, fde = CallFrameInfo.search_fde_offset(eh_frame, tab, modrel, slide)
        loc = loc + Int(sectionoffset(tab.hdr_sec))
        return (loc, fde)
    end
end

function probably_in_entrypoint(h, ip)
    start = Gallium.X86_64.BasicRegs(deref(first(filter(x->isa(deref(x),MachO.thread_command),LoadCmds(h))))).rip[]
    start -= Gallium.first_actual_segment(h).vmaddr
    # Default OS X _start is 63 bytes
    start <= ip <= start+63
end

function entry_cfa(mod, r)
    rs = DWARF.CallFrameInfo.RegStates()
    regs = Gallium.X86_64.inverse_dwarf
    cfa_addr = RemotePtr{Void}(get_dwarf(r, regs[:rbp])[])
    rs[regs[:rip]] = DWARF.CallFrameInfo.Offset(0x0, false)
    cfa_addr, rs, DWARF.CallFrameInfo.CIE(0,0,0,regs[:rip],UInt8[]), 0
end

function modulerel(mod, base, ip)
    ret = (ip - base)
end

realize_cie(mod::Module, fde) = realize_cie(mod.ciecache, fde)

function frame(s, modules, r; stacktop = false)
    base, mod = find_module(modules, UInt(ip(r)))
    modrel = UInt(modulerel(mod, base, UInt(ip(r))))
    loc, fde = try
        find_fde(mod, modrel)
    catch e
        # As a special case, if we're in a MachO executable's entry point,
        # we probably don't have unwind info. TODO: Remove this once we support
        # compact unwind info which the entry point does have.
        if isa(handle(mod), MachO.MachOHandle) && readheader(handle(mod)).filetype == MachO.MH_EXECUTE
            probably_in_entrypoint(handle(mod), modrel) && return entry_cfa(mod, r)
        end
        rethrow(e)
    end
    ciecache = nothing
    isa(mod, Module) && (ciecache = mod.ciecache)
    cie, ccoff = realize_cieoff(fde, ciecache)
    # Compute CFA
    target_delta = modrel - loc - (stacktop?0:1)
    @assert target_delta < UInt(CallFrameInfo.fde_range(fde, cie))
    # out = IOContext(STDOUT, :reg_map => Gallium.X86_64.dwarf_numbering)
    # drs = CallFrameInfo.RegStates()
    # CallFrameInfo.dump_program(out, cie, target = UInt(target_delta), rs = drs); println(out)
    # CallFrameInfo.dump_program(out, fde, cie = cie, target = UInt(target_delta), rs = drs)
    rs = CallFrameInfo.evaluate_program(fde, UInt(target_delta), cie = cie, ciecache = ciecache, ccoff=ccoff)
    local cfa_addr
    if !CallFrameInfo.isdwarfexpr(rs.cfa)
        if rs.cfa.flag != CallFrameInfo.Flag.Val
            error("invalid CFA value $(rs.cfa)")
        end
        cfa_addr = RemotePtr{Void}(convert(Int, get_dwarf(r, Int(rs.cfa.base)) + rs.cfa.offset))
    else
        sm = DWARF.Expressions.StateMachine{typeof(unsigned(ip(r)))}()
        getreg(reg) = get_dwarf(r, reg)
        getword(addr) = get_word(s, addr)[]
        addr_func(addr) = addr
        loc = DWARF.Expressions.evaluate_simple_location(sm, rs.cfa_expr.opcodes, getreg, getword, addr_func, :NativeEndian)
        if isa(loc, DWARF.Expressions.RegisterLocation)
            cfa_addr = RemotePtr{Void}(get_dwarf(r, loc.i))
        else
            cfa_addr = RemotePtr{Void}(loc.i)
        end
    end
    cfa_addr, rs, cie, UInt64(target_delta)
end

function symbolicate(modules, ip)
    base, mod = find_module(modules, ip)
    modrel = UInt(modulerel(mod, base, ip))
    loc, fde = find_fde(mod, modrel)
    cie = realize_cie(fde)
    #loc = initial_loc(fde, cie)
    sections = Sections(handle(mod))
    #=if handle(mod).file.header.e_type == ELF.ET_REL
        eh_frame = first(filter(x->sectionname(x) == ".eh_frame",sections))
        fbase += deref(eh_frame).sh_addr - sectionoffset(eh_frame)
    end=#
    local syms
    if isa(handle(mod), ELF.ELFHandle)
        secs = collect(filter(x->sectionname(x) == ".symtab",sections))
        isempty(secs) && (secs = collect(filter(x->sectionname(x) == ".dynsym",sections)))
        syms = ELF.Symbols(secs[1])
    else
        syms = MachO.Symbols(handle(mod))
    end
    idx = findfirst(syms) do x
        isundef(x) && return false
        value = symbolvalue(x, sections)
        #@show value
        value == loc
    end
    idx == 0 && return "???"
    symname(syms[idx]; strtab = StrTab(syms))
end

function fetch_cfi_value(s, r, resolution, cfa_addr)
    if CallFrameInfo.issame(resolution)
        return get_dwarf(r, reg)
    elseif resolution.flag == CallFrameInfo.Flag.Val#isa(resolution, CallFrameInfo.Offset)
        if resolution.base == CallFrameInfo.RegCFA
            return convert(UInt64, convert(UInt64,cfa_addr)%Int64 + resolution.offset)
        else
            return convert(UInt64, get_dwarf(r, Int(resolution.base))%Int64 + resolution.offset)
        end
    elseif resolution.flag == CallFrameInfo.Flag.Deref
        addr = RemotePtr{Ptr{Void}}(fetch_cfi_value(s, r, CallFrameInfo.RegState(resolution.base, resolution.offset, CallFrameInfo.Flag.Val), cfa_addr))
        return get_word(s, addr)
    else
        error("Unknown resolution $resolution")
    end
end

function unwind_step(s, modules, r; stacktop = false, ip_only = false)
    new_registers = copy(r)
    # A priori the registers in the new frame will not be valid, we copy them
    # over from above still and propagate as usual in case somebody wants to
    # look at them.
    invalidate_regs!(new_registers)
    cfa, rs, cie, delta = try
        frame(s, modules, r; stacktop = stacktop)
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
    CallFrameInfo.isundef(rs[cie.return_reg]) && return (false, r)
    # Find current frame's return address, (i.e. the new frame's ip)
    set_ip!(new_registers, fetch_cfi_value(s, r, rs[cie.return_reg], cfa))
    # Now set other registers recorded in the CFI
    if !ip_only
        for reg in keys(rs.values)
            resolution = rs.values[reg]
            reg == cie.return_reg && continue
            set_dwarf!(new_registers, reg, fetch_cfi_value(s, r, resolution, cfa))
        end
    end
    UInt(ip(new_registers)) == 0 &&  return (false, r)
    (true, new_registers)
end

end
