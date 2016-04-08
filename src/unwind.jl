module Unwinder

using CallFrameInfo
using ..Registers

function frame(s, modules, r::RegisterSet)
    mod = find_module(modules, ip(r))
    fde = find_fde(mod, ip(r))
    cie = realize_cie(fde)
    # Compute CFA
    target_delta = moudlerel(mod, ip(r)) - initial_loc(fde)
    rs = CallFrameInfo.evaluate_program(fde, target_delta, cie)
    local cfa_addr
    if isa(rs.cfa, Tuple{Int,Int})
        cfa_addr = convert(Int, dwarf_reg(r, rs.cfa[1]) + rs.cfa[2])
    else
        error("DWARF expr for CFA not supported yet")
    end
    rs.cfa, rs, cie
end

function unwind_step(s, modules, r::RegisterSet)
    new_registers = copy(r)
    # A priori the registers in the new frame will not be valid, we copy them
    # over from above still and propagate as usual in case somebody wants to
    # look at them.
    invalidate_regs!(new_registers)
    cfa, rs, cie = frame(modules, r)
    # By definition, the next frame's stack pointer is our CFA
    set_sp!(new_registers, cfa)
    # Find current frame's return address, (i.e. the new frame's ip)
    set_ip!(new_registers, fetch_cfi_value(s, r, rs[cie.return_reg], cfa_addr))
    # Now set other registers recorded in the CFI
    for (reg, resolution) in s.values
        if isa(resolution, CallFrameInfo.Same)
            set_dwarf!(new_registers, reg, get_dwarf(r, reg))
        elseif isa(resolution, CallFrameInfo.Offset)
            if resolution.is_val
                set_dwarf!(new_registers, reg, cfa + resolution.offset)
            else
                set_dwarf!(new_registers, reg, get_word(s, cfa + resolution.offset))
            end
        elseif isa(resolution, CallFrameInfo.Expr)
            error("Not implemented")
        elseif isa(resolution, CallFrameInfo.Reg)
            set_dwarf!(new_registers, reg, get_dwarf(r, resolution.n))
        else
            error("Unknown resolution")
        end
    end
end

end
