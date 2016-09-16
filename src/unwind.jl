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
using Gallium: find_module, Module, load, make_fdetab, make_inverse_symtab
import Gallium: symbolicate

typealias CFICacheEntry Tuple{CallFrameInfo.RegStates,CallFrameInfo.CIE,UInt}
type CFICache
    sz :: Int
    values :: Dict{RemotePtr{Void}, CFICacheEntry}
end

CFICache(sz::Int) = CFICache(sz, Dict{RemotePtr{Void}, Tuple{CallFrameInfo.RegStates,CallFrameInfo.CIE,UInt}}())

function get_word(s::Gallium.LocalSession, ptr::RemotePtr)
    Gallium.Hooking.mem_validate(UInt(ptr), sizeof(Ptr{Void})) || error("Invalid load")
    UInt64(load(s, RemotePtr{Gallium.intptr(Gallium.getarch(s))}(ptr)))
end
get_word(s, ptr::RemotePtr) = UInt64(load(s, RemotePtr{Gallium.intptr(Gallium.getarch(s))}(ptr)))

function find_fde(mod, modrel)
    slide = 0
    eh_frame = Gallium.find_ehframes(mod)[1]
    if isa(mod, Module) && isnull(mod.ehfr)
        isnull(mod.FDETab) &&
            (mod.FDETab = Nullable(make_fdetab(mod.base, mod)))
        return CallFrameInfo.search_fde_offset(eh_frame, get(mod.FDETab),
            modrel, slide, is_eh_not_debug = mod.is_eh_not_debug)
    else
        tab = Gallium.find_ehfr(mod)
        modrel = Int(modrel)-Int(sectionoffset(tab.hdr_sec))
        slide = Int(sectionoffset(tab.hdr_sec)) - Int(sectionoffset(eh_frame))
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
    rs.cfa = DWARF.CallFrameInfo.Offset(
        DWARF.CallFrameInfo.RegNum(regs[:rbp]), 0)
    rs[regs[:rip]] = DWARF.CallFrameInfo.Load(DWARF.CallFrameInfo.RegCFA, 0)
    rs, DWARF.CallFrameInfo.CIE(0,0,0,regs[:rip],UInt8[]), UInt64(0)
end

function modulerel(mod, base, ip)
    ret = (ip - base)
end

get_ciecache(_) = nothing
function get_ciecache(mod::Module)
    if isnull(mod.ciecache) && !isnull(mod.eh_frame)
        CallFrameInfo.precompute(get(mod.eh_frame), mod.is_eh_not_debug)
    end
    isnull(mod.ciecache) && return nothing
    get(mod.ciecache)
end

realize_cie(mod::Module, fde) = realize_cie(get_ciecache(mod), fde)

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
    ciecache = get_ciecache(mod)
    cie::CIE, ccoff = realize_cieoff(fde, ciecache)
    # Compute CFA
    target_delta::UInt64 = modrel - loc - (stacktop?0:1)
    @assert target_delta < UInt(CallFrameInfo.fde_range(fde, cie))
    #out = STDOUT #IOContext(STDOUT, :reg_map => Gallium.X86_64.dwarf_numbering)
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

immutable TransformedArray{A,T,F} <: AbstractArray{T,1}
    arr::A
    func::F
end
TransformedArray{T,F}(a::AbstractArray{T,1}, func::F) =
    TransformedArray{typeof(a), T, F}(a, func)
Base.length(a::TransformedArray) = length(a.arr)
Base.size(a::TransformedArray) = size(a.arr)
Base.getindex(a::TransformedArray, idx) = a.func(a.arr[idx])

symbolicate(modules, ip) = symbolicate(Gallium.LocalSession(), modules, ip)
function symbolicate(session, modules, ip)
    base, mod = try
        find_module(session, modules, ip)
    catch err
        if !isa(err, ErrorException) || !contains(err.msg, "not found")
            rethrow(err)
        end
        return (false, "<Unknown Module>")
    end
    symbolicate(session, base, mod, ip)
end
function symbolicate(session, base, mod, ip)
    modrel = UInt(modulerel(mod, base, ip))
    loc = modrel
    approximate = true
    try
        if !isnull(mod.eh_frame)
            loc, fde = find_fde(mod, modrel)
            approximate = false
        elseif !isnull(mod.xpdata)
            loc = find_seh_entry(mod, modrel).start
            approximate = false
        end
    end
    sections = Sections(Gallium.dhandle(mod))
    syms = Gallium.get_syms(mod)
    function correct_symbol(x)
        isundef(x) && return (false, UInt64(0))
        !isa(handle(mod), COFF.COFFHandle) || COFF.isfunction(x) || return (false, UInt64(0))
        isa(handle(mod), ELF.ELFHandle) &&
            (ELF.st_type(x) != ELF.STT_FUNC) && return (false, UInt64(0))
        value = symbolvalue(x, sections)
        #@show value
        (true, value)
    end
    if isa(mod, Gallium.Module)
        isnull(mod.inverse_symtab) &&
            (mod.inverse_symtab = Nullable(make_inverse_symtab(Gallium.dhandle(mod))))
        idx = searchsortedfirst(TransformedArray(get(mod.inverse_symtab),
            idx->symbolvalue(syms[idx], sections)), loc)
        if !approximate
            while idx <= length(syms)
                ok, value = correct_symbol(syms[get(mod.inverse_symtab)[idx]])
                (mod.is_jit_dobj) && (value -= base)
                (ok && value == loc) && break
                ok && value > loc && (#=idx = 0;=# break)
                idx += 1
            end
        end
        (idx == length(get(mod.inverse_symtab))+1) && (idx = 0)
        idx != 0 && (idx = get(mod.inverse_symtab)[idx])
    else
        @assert !approximate
        idx = findfirst(syms) do sym
            ok, value = correct_symbol(sym)
            ok && value == loc
        end
    end
    idx == 0 && return "???"
    name = symname(syms[idx]; strtab = StrTab(syms))
    (!approximate, name)
end

function fetch_cfi_val_value(s, r, resolution, cfa_addr)
    if resolution.base == CallFrameInfo.RegCFA
        return (convert(UInt64,cfa_addr)%Int64 + resolution.offset) % UInt64
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
        addr = RemotePtr{Void}(fetch_cfi_val_value(s, r, new_resolution, cfa_addr))
        return get_word(s, addr)
    else
        error("Unknown resolution $resolution")
    end

end

function unwind_step_frame_pointer!(new_registers, s)
    # We don't really know anything about how to unwind here, but let's
    # try frame pointer based unwinding and hope FPO isn't enabled
    # TODO: Maybe try assembly profiling
    if isa(getarch(s),X86_64.X86_64Arch)
        old_rbp = get_dwarf(new_registers, :rbp)
        set_dwarf!(new_registers, :rbp, get_word(s, RemotePtr{UInt64}(old_rbp)))
        set_ip!(new_registers, get_word(s, RemotePtr{UInt64}(old_rbp+8)))
    else
        old_ebp = get_dwarf(new_registers, :ebp)
        set_dwarf!(new_registers, :ebp, get_word(s, RemotePtr{UInt32}(old_ebp)))
        set_ip!(new_registers, get_word(s, RemotePtr{UInt32}(old_ebp+4)))
    end
    new_registers
end

using Gallium: X86_64
function unwind_step(s, modules, r, cfi_cache = nothing; stacktop = false, ip_only = false, allow_frame_based = true)
    new_registers = copy(r)
    # A priori the registers in the new frame will not be valid, we copy them
    # over from above still and propagate as usual in case somebody wants to
    # look at them.
    invalidate_regs!(new_registers)

    # First, find the module we're currently in
    base, mod = find_module(s, modules, UInt(ip(r)))
    modrel = UInt64(ip(r)) - base

    # Determine if we have windows or DWARF unwind info
    if !isnull(mod.eh_frame)
        cf = try
            frame(s, base, mod, r, stacktop, cfi_cache)
        catch e
            allow_frame_based &&
                return (true, unwind_step_frame_pointer!(new_registers, s))
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
    elseif !isnull(mod.xpdata)
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
    else
        allow_frame_based &&
            return (true, unwind_step_frame_pointer!(new_registers, s))
        error("Ununwindable module")
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
