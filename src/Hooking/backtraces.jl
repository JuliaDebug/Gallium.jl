
if OS_NAME == :Darwin
    const unw_getcontext = :unw_getcontext
    const unw_init = :unw_init_local_dwarf
    const unw_step = :unw_step
    const unw_get_reg = :unw_get_reg
    const UNW_REG_IP = -1
else
    const unw_getcontext = :jl_unw_getcontext
    const unw_init = :jl_unw_init_local
    const unw_step = :jl_unw_step
    const unw_get_reg = :jl_unw_get_reg
    const UNW_X86_64_RAX   =  0
    const UNW_X86_64_RDX   =  1
    const UNW_X86_64_RCX   =  2
    const UNW_X86_64_RBX   =  3
    const UNW_X86_64_RSI   =  4
    const UNW_X86_64_RDI   =  5
    const UNW_X86_64_RBP   =  6
    const UNW_X86_64_RSP   =  7
    const UNW_X86_64_R8    =  8
    const UNW_X86_64_R9    =  9
    const UNW_X86_64_R10   = 10
    const UNW_X86_64_R11   = 11
    const UNW_X86_64_R12   = 12
    const UNW_X86_64_R13   = 13
    const UNW_X86_64_R14   = 14
    const UNW_X86_64_R15   = 15
    const UNW_X86_64_RIP   = 16
    const UNW_REG_IP       = UNW_X86_64_RIP

    const UC_MCONTEXT_GREGS_RSP = 0xa0
    const UC_MCONTEXT_GREGS_RIP = 0xa8
end

function get_reg(cursor, reg)
    res = Ref{UInt64}()
    ccall(unw_get_reg, Cint, (Ptr{Void}, Cint, Ref{UInt64}), cursor, reg, res)
    res[]
end
get_ip(cursor) = get_reg(cursor, UNW_REG_IP)

# The first step is hooking specific, since the frame chain has not yet been
# established. It's also very simple since all we need to do is pop the return
# address from the stack and store it as the new IP
function step_first!(RC)
    RC.data[RegisterMap[:rip]] = unsafe_load(convert(Ptr{UInt},RC.data[RegisterMap[:rsp]]))
    RC.data[RegisterMap[:rsp]] += sizeof(Ptr{Void})
end

function rec_backtrace(callback, RC)
    cursor = Array(UInt8, 1000)
    ccall(unw_init, Void, (Ptr{Void}, Ptr{Void}), cursor, RC.data)
    callback(cursor)
    step_first!(RC)
    ccall(unw_init, Void, (Ptr{Void}, Ptr{Void}), cursor, RC.data)
    callback(cursor)
    while ccall(unw_step, Cint, (Ptr{Void},), cursor) > 0
        callback(cursor)
    end
end

function rec_backtrace(RC)
    ips = Array(UInt64, 0)
    rec_backtrace(cursor->push!(ips,get_ip(cursor)), RC)
    ips
end

function local_RC()
    data = Array(UInt, 100)
    ccall(unw_getcontext,Void,(Ptr{Void},),data)
    RegisterContext(data)
end
