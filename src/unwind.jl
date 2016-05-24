module Unwinder

using DWARF
using DWARF.CallFrameInfo
import DWARF.CallFrameInfo: realize_cie, RegStates, CIE
using ObjFileBase
using ObjFileBase: handle
using Gallium
using ..Registers
using ..Registers: ip
using ObjFileBase
using ObjFileBase: Sections, mangle_sname
using ELF
using MachO
using COFF
using Gallium: find_module, Module, load

typealias CFICacheEntry Tuple{CallFrameInfo.RegStates,CallFrameInfo.CIE,UInt}
type CFICache
    sz :: Int
    values :: Dict{RemotePtr{Void}, CFICacheEntry}
end

CFICache(sz::Int) = CFICache(sz, Dict{RemotePtr{Void}, Tuple{CallFrameInfo.RegStates,CallFrameInfo.CIE,UInt}}())

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

function compute_register_states(s, base, mod, r, stacktop, ::Void)
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
    cie::CIE, ccoff = realize_cieoff(fde, ciecache)
    # Compute CFA
    target_delta::UInt64 = modrel - loc - (stacktop?0:1)
    @assert target_delta < UInt(CallFrameInfo.fde_range(fde, cie))
    #out = IOContext(STDOUT, :reg_map => Gallium.X86_64.dwarf_numbering)
    #drs = CallFrameInfo.RegStates()
    #CallFrameInfo.dump_program(out, cie, target = UInt(target_delta), rs = drs); println(out)
    #CallFrameInfo.dump_program(out, fde, cie = cie, target = UInt(target_delta), rs = drs)
    CallFrameInfo.evaluate_program(fde, UInt(target_delta), cie = cie, ciecache = ciecache, ccoff=ccoff)::RegStates, cie, target_delta
end

function compute_register_states(s, base, mod, r, stacktop, cfi_cache::CFICache)
    pc = RemotePtr{Void}(UInt(ip(r)))
    if haskey(cfi_cache.values, pc)
        return cfi_cache.values[pc]::CFICacheEntry
    else
        result = compute_register_states(s, base, mod, r, stacktop, nothing)::CFICacheEntry
        if length(cfi_cache.values) < cfi_cache.sz
            cfi_cache.values[pc] = result
        end
        result::CFICacheEntry
    end
end

immutable Frame
    cfa_addr::RemotePtr{Void}
    rs::RegStates
    cie::CIE
    target_delta::UInt64
end

function evaluate_cfi_expr(opcodes, s, r, rs)
    sm = DWARF.Expressions.StateMachine{UInt64}() # typeof(unsigned(ip(r)))
    getreg(reg) = get_dwarf(r, reg)
    getword(addr) = get_word(s, RemotePtr{UInt64}(addr))[]
    addr_func(addr) = addr
    loc = DWARF.Expressions.evaluate_simple_location(sm, opcodes, getreg, getword, addr_func, :NativeEndian)
    if isa(loc, DWARF.Expressions.RegisterLocation)
        addr = RemotePtr{Void}(get_dwarf(r, loc.i))
    else
        addr = RemotePtr{Void}(loc.i)
    end
    addr
end
evaluate_cfa_expr(s, r, rs) = evaluate_cfi_expr(rs.cfa_expr.opcodes, s, r, rs)

function compute_cfa_addr(s, r, rs)
    local cfa_addr
    if !CallFrameInfo.isdwarfexpr(rs.cfa)
        if rs.cfa.flag != CallFrameInfo.Flag.Val
            error("invalid CFA value $(rs.cfa)")
        end
        cfa_addr = RemotePtr{Void}(convert(Int, get_dwarf(r, Int(rs.cfa.base)) + rs.cfa.offset))
    else
        cfa_addr = evaluate_cfa_expr(s, r, rs)
    end
end

function frame(s, base, mod, r, stacktop :: Bool, cfi_cache)
    rs, cie, target_delta = compute_register_states(s, base, mod, r, stacktop, cfi_cache)::CFICacheEntry
    Frame(compute_cfa_addr(s, r, rs), rs, cie, UInt64(target_delta))
end

function symbolicate(modules, ip)
    base, mod = find_module(modules, ip)
    modrel = UInt(modulerel(mod, base, ip))
    if isnull(mod.xpdata)
        loc, fde = find_fde(mod, modrel)
    else
        loc = find_seh_entry(mod, modrel).start
    end
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
    elseif isa(handle(mod), MachO.MachOHandle)
        syms = MachO.Symbols(handle(mod))
    elseif isa(handle(mod), COFF.COFFHandle)
        syms = COFF.Symbols(handle(mod))
    end
    idx = findfirst(syms) do x
        isundef(x) && return false
        !isa(handle(mod), COFF.COFFHandle) || COFF.isfunction(x) || return false
        value = symbolvalue(x, sections)
        #@show value
        value == loc
    end
    idx == 0 && return "???"
    symname(syms[idx]; strtab = StrTab(syms))
end

function fetch_cfi_val_value(s, r, resolution, cfa_addr)
    if resolution.base == CallFrameInfo.RegCFA
        return convert(UInt64, convert(UInt64,cfa_addr)%Int64 + resolution.offset)
    else
        return convert(UInt64, get_dwarf(r, Int(resolution.base))%Int64 + resolution.offset)
    end
end

function fetch_cfi_value(s, r, rs, reg, cfa_addr)
    resolution = rs.values[reg]
    if CallFrameInfo.isdwarfexpr(resolution)
        ve = rs.values_expr[reg]
        val = evaluate_cfi_expr(ve.opcodes, s, r, rs)
        ve.is_val || (val = get_word(s,RemotePtr{UInt64}(val)))
        return val
    elseif CallFrameInfo.issame(resolution)
        return get_dwarf(r, reg)
    elseif resolution.flag == CallFrameInfo.Flag.Val#isa(resolution, CallFrameInfo.Offset)
        return fetch_cfi_val_value(s, r, resolution, cfa_addr)
    elseif resolution.flag == CallFrameInfo.Flag.Deref
        new_resolution = CallFrameInfo.RegState(resolution.base, resolution.offset, CallFrameInfo.Flag.Val)
        addr = RemotePtr{Ptr{Void}}(fetch_cfi_val_value(s, r, new_resolution, cfa_addr))
        return get_word(s, addr)
    else
        error("Unknown resolution $resolution")
    end

end

using Gallium: X86_64
function unwind_step(s, modules, r, cfi_cache = nothing; stacktop = false, ip_only = false)
    new_registers = copy(r)
    # A priori the registers in the new frame will not be valid, we copy them
    # over from above still and propagate as usual in case somebody wants to
    # look at them.
    invalidate_regs!(new_registers)
    
    # First, find the module we're currently in
    base, mod = find_module(modules, UInt(ip(r)))
    modrel = UInt64(ip(r)) - base
    
    # Determine if we have windows or DWARF unwind info
    if isnull(mod.xpdata)
        cf = try
            frame(s, base, mod, r, stacktop, cfi_cache)
        catch e
            rethrow(e)
            return (false, r)
        end

        # By definition, the next frame's stack pointer is our CFA
        set_sp!(new_registers, UInt(cf.cfa_addr))
        CallFrameInfo.isundef(cf.rs[cf.cie.return_reg]) && return (false, r)
        # Find current frame's return address, (i.e. the new frame's ip)
        set_ip!(new_registers, fetch_cfi_value(s, r, cf.rs, cf.cie.return_reg, cf.cfa_addr))
        # Now set other registers recorded in the CFI
        if !ip_only
            for reg in keys(cf.rs.values)
                resolution = cf.rs.values[reg]
                reg == cf.cie.return_reg && continue
                set_dwarf!(new_registers, reg, fetch_cfi_value(s, r, cf.rs, reg, cf.cfa_addr))
            end
        end
    else
        entry = find_seh_entry(mod, modrel)
        offs = modrel - entry.start
        frameaddr = 0
        if entry.info.FrameRegOff != 0
            reg = entry.info.FrameRegOff & 0xf
            regoff = (entry.info.FrameRegOff & 0xf0) >> 4
            frameaddr = get_dwarf(r, X86_64.seh_numbering[reg]) -
                16*regoff
        end
        set_dwarf!(new_registers, :rsp, get_dwarf(r, :rsp))
        i = 1
        codes = reinterpret(UNWIND_CODE, entry.opcodes)
        while i <= length(entry.opcodes) 
            op = codes[i]
            run = op.PrologueOffset <= offs
            old_rsp = get_dwarf(new_registers, :rsp)
            opcode, info = Gallium.opinfo(op)
            if opcode == UWOP_PUSH_NONVOL
                if run
                    # Pop the register
                    set_dwarf!(new_registers, X86_64.seh_numbering[info],
                        get_word(s, RemotePtr{UInt64}(old_rsp)))
                    set_dwarf!(new_registers, :rsp, old_rsp+8)
                end
                i += 1
            elseif opcode == UWOP_ALLOC_LARGE || opcode == UWOP_ALLOC_SMALL
                # Undo the allocation
                size, nskip = Gallium.compute_alloc_op_size(entry.opcodes, i)
                run && set_dwarf!(new_registers, :rsp, old_rsp + size)
                i += nskip
            elseif opcode == UWOP_SAVE_XMM128
                # TODO
                i += 2
            elseif opcode == UWOP_SET_FPREG
                set_dwarf!(new_registers, :rsp, frameaddr)
                i += 1
            else
                error("Unknown operation $(op.Operation&0xf)")
            end
        end
        # The return address should now be on the stack. Pop it as well
        old_rsp = get_dwarf(new_registers, :rsp)
        set_ip!(new_registers, get_word(s, RemotePtr{UInt64}(old_rsp)))
        set_dwarf!(new_registers, :rsp, old_rsp+8)
    end
    UInt(ip(new_registers)) == 0 &&  return (false, r)
    (true, new_registers)
end

# Win64 unwinding
using Gallium: PData, RUNTIME_FUNCTION, UNWIND_CODE,
    UWOP_PUSH_NONVOL, UWOP_ALLOC_LARGE, UWOP_ALLOC_SMALL,
    UWOP_SET_FPREG, UWOP_SAVE_NONVOL, UWOP_SAVE_NONVOL_FAR,
    UWOP_SAVE_XMM128, UWOP_SAVE_XMM128_FAR, UWOP_PUSH_MACHFRAME 

function find_seh_entry(mod, modrel)
    slide = 0
    xpref = get(mod.xpdata)
    idx = searchsortedlast(PData(xpref.pdata), RUNTIME_FUNCTION(modrel,0,0), by = x->Int64(x.startoff))
    return xpref[idx]
end


end
