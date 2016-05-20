using Gallium
"""
Attempt to emulate the first instruction in insts. Return value indicates whether
the instruction was known.
"""
function instemulate!(insts, vm, RC)
    if insts[1] == 0x55 # pushq %rbp
        rsp = get_dwarf(RC, inverse_dwarf[:rsp])
        set_dwarf!(RC, inverse_dwarf[:rsp], rsp-8)
        Gallium.store!(vm, Gallium.RemotePtr{UInt64}(rsp-8),
            get_dwarf(RC, inverse_dwarf[:rbp]))
        set_ip!(RC, UInt(Gallium.ip(RC))+1)
        return true
    end
    @show insts
    return false
end
