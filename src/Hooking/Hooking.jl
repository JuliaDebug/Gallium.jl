module Hooking

using Gallium
using Gallium: X86_64, Registers
using Gallium.Registers: ip

export hook, unhook

typealias MachTask Ptr{Void}
typealias KernReturn UInt32

immutable MemoryRegion
    @static if is_apple()
        task::MachTask
    end
    addr::Ptr{Void}
    size::UInt64
end

region_to_array(region::MemoryRegion) =
    unsafe_wrap(Array, convert(Ptr{UInt8}, region.addr), (region.size,), false)

# Windows Wrappers
@static if is_windows()
    to_page(addr, size) =
        (@assert size <= 4096;
        MemoryRegion(
            addr-(reinterpret(UInt, addr)%4096),1))

    function VirtualProtect(region, perms)
        oldPerm = Ref{UInt32}()
        succ = ccall(:VirtualProtect,stdcall,Cint,(Ptr{Void}, Csize_t, UInt32, Ptr{UInt32}), region.addr, 4096, perms, oldPerm)
        succ == 0 && error(Libc.GetLastError())
        nothing
    end

    immutable MEMORY_BASIC_INFORMATION64
        BaseAddress::UInt64
        AllocationBase::UInt64
        AllocationProtect::UInt32
        __alignment1::UInt32
        RegionSize::UInt64
        State::UInt32
        Protect::UInt32
        Type::UInt32
        __alignment2::UInt32
    end

    function mem_validate(addr, length)
        ret = Ref{MEMORY_BASIC_INFORMATION64}()
        succ = ccall(:VirtualQuery, stdcall, Cint, (Ptr{Void}, Ptr{MEMORY_BASIC_INFORMATION64}, Csize_t), Ptr{Void}(addr), ret, sizeof(MEMORY_BASIC_INFORMATION64))
        if succ == 0
            error(Libc.GetLastError())
        end
        (ret[].Protect & (PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_READONLY | PAGE_READWRITE)) != 0
    end

    const PAGE_READWRITE         = 0x04
    const PAGE_READONLY          = 0x02
    const PAGE_EXECUTE_READ      = 0x20
    const PAGE_EXECUTE_READWRITE = 0x40
    const PAGE_EXECUTE_WRITECOPY = 0x80
    const PAGE_NOACCESS          = 0x01

    const MEM_COMMIT             = 0x1000
    const MEM_RESERVE            = 0x2000
end

# mach vm wrappers
@static if is_apple()

    mach_task_self() = ccall(:mach_task_self,MachTask,())

    to_page(addr, size) =
        (@assert size <= 4096;
        MemoryRegion(mach_task_self(),
            addr-(reinterpret(UInt, addr)%4096),1))

    const KERN_SUCCESS     = 0x0

    const VM_PROT_NONE     = 0x0
    const VM_PROT_READ     = 0x1
    const VM_PROT_WRITE    = 0x2
    const VM_PROT_EXECUTE  = 0x4
    const VM_PROT_COPY     = 0x8

    function mach_vm_protect(task::MachTask, addr::Ptr{Void}, size::UInt64,
        prots; set_maximum::Bool = false)

        ccall(:mach_vm_protect, KernReturn,
            (MachTask, Ptr{Void}, UInt64, Bool, UInt32),
            task, addr, size, set_maximum, prots)
    end
    mach_vm_protect(region, prots) = mach_vm_protect(region.task,
        region.addr, region.size, prots)

    const VM_FLAGS_FIXED    = 0x0000
    const VM_FLAGS_ANYWHERE = 0x0001
    const VM_FLAGS_PURGABLE = 0x0002
    const VM_FLAGS_NO_CACHE = 0x0010

    function mach_vm_allocate(task, size; addr = C_NULL)
        x = Ref{Ptr{Void}}()
        x[] = addr
        ret = ccall(:mach_vm_allocate, KernReturn,
            (MachTask, Ref{Ptr{Void}}, Csize_t, Cint), task, x, size,
            addr == C_NULL ? VM_FLAGS_ANYWHERE : VM_FLAGS_FIXED)
        (ret, MemoryRegion(task,x[],size))
    end
    mach_vm_allocate(size) = mach_vm_allocate(mach_task_self(),size)

    function mach_check(status,args...)
        if status != KERN_SUCCESS
            error("Mach system call failed (error code $status)")
        end
        @assert length(args) <= 1
        length(args) == 1 ? args[1] : nothing
    end

    const VM_REGION_BASIC_INFO_64 = 9
    const KERN_INVALID_ADDRESS = 1
    function mem_validate(addr, length)
        x = Array(UInt8,2)
        addr_info = Ref{Ptr{Void}}(addr)
        size_info = Ref{Csize_t}(length)
        flavor = VM_REGION_BASIC_INFO_64
        buf = Array(UInt,1000)
        buf_size = Ref{Csize_t}(1000)
        object_name = Ref{Ptr{Void}}(C_NULL)
        ret = ccall(:mach_vm_region, KernReturn, (Ptr{Void}, Ptr{Ptr{Void}}, Ptr{Csize_t}, Csize_t, Ptr{Void}, Ptr{Csize_t}, Ptr{Void}),
            mach_task_self(), addr_info, size_info, flavor, buf, buf_size, object_name)
        ret == 0 &&
            addr_info[] <= Ptr{Void}(addr) &&
            Ptr{Void}(addr + length) < (addr_info[] + size_info[])
    end

end

@static if is_linux()
    to_page(addr, size) = (@assert size <= 4096;
        MemoryRegion(addr-(reinterpret(UInt, addr)%4096),1))

    mprotect(region, flags) = ccall(:mprotect, Cint,
        (Ptr{Void}, Csize_t, Cint), region.addr, region.size, flags)

    function mem_validate(addr, length)
        x = Array(UInt8,2)
        ret = ccall(:mincore, Cint, (Ptr{Void}, Csize_t, Ptr{UInt8}), to_page(addr, length).addr, length, x)
        ret == 0
    end

    const PROT_READ	 =  0x1
    const PROT_WRITE =  0x2
    const PROT_EXEC	 =  0x4
    const PROT_NONE	 =  0x0
end

include("backtraces.jl")

immutable Hook
    addr::Ptr{Void}
    orig_data::Vector{UInt8}
    callback::Function
end

using Base.llvmcall
hooks = Dict{Ptr{Void},Hook}()

immutable Deopt
    addr::Ptr{Void}
end

# The text section of jumpto-x86_64-macho.o minus one byte
const resume_length = 0x6c

function hook_asm_template(hook_addr, target_addr; call = true)
    diff = (target_addr - (hook_addr + 5))%Int32
    @show diff
    @assert typemin(Int32) <= diff <= typemax(Int32)
    [ call ? 0xe8 : 0xe9; reinterpret(UInt8, [Int32(diff)]); ]
end

function instrument_jmp_template(alt_stack, entry_func, exit_func)
    instrument_exit = exit_func != 0
    UInt8[
        0x41; 0x53; 	   # pushq	%r11
        0x49; 0x89; 0xe3   # movq %rsp, %r11
        # movq alt_stack, %rsp
        0x48; 0xbc; reinterpret(UInt8, [alt_stack]);
        0x41; 0x53; 	   # pushq	%r11
        0x41; 0x53; 	   # pushq	%r11
        # movq entry_func, %r11
        0x49; 0xbb; reinterpret(UInt8, [entry_func]);
        0x41; 0xff; 0xd3;       # callq *%r11
        0x41; 0x5b;             # popq	%r11
        (instrument_exit ? [
            # movq	8(%r11), %r11
            0x4d; 0x8b; 0x5b; 0x08;
            0x41; 0x53; 	   # pushq	%r11
            0x41; 0x5b;        # popq	%r11
        ] : []);
        0x5c;                   # popq %rsp
        instrument_exit ? [
            # movq exit_func, %r11
            0x49; 0xbb; reinterpret(UInt8, [exit_func]);
            0x4c; 0x89; 0x5c; 0x24; 0x08; # movq	%r11, 8(%rsp)
        ] : [];
        0x41; 0x5b;             # popq	%r11
    ]
end

function return_hook_template(alt_stack, func)
    @assert func != 0
    [
        0x41; 0x53;         # pushq	%r11
        0x41; 0x53;         # pushq	%r11
        0x49; 0x89; 0xe3    # movq %rsp, %r11
        # movq alt_stack-0x10, %rsp
        0x48; 0xbc; reinterpret(UInt8, [alt_stack-0x10]);
        0x41; 0x54;        # pushq  %r12
        0x41; 0x53; 	   # pushq	%r11
        0x49; 0xbb; reinterpret(UInt8, [func]);
        0x41; 0xff; 0xd3;  # callq *%r11
        0x41; 0x5b;        # popq	%r11
        # movq	8(%rsp), %r12
        0x4c; 0x8b; 0x64; 0x24; 0x08;
        0x4d; 0x89; 0x63; 0x08; # movq	%r12, 8(%r11)
        0x41; 0x5c;             # popq	%r12
        0x4c; 0x89; 0xdc;       # movq	%r11, %rsp
        0x41; 0x5b;             # popq	%r11
        0xc3;                   # retq
    ]
end


function hook_asm_template(addr)
    [
        0x90; # 0xcc
        0x50; #pushq   %rax
        # movq $hookto, %rax
        0x48; 0xb8; reinterpret(UInt8, [addr]);
        0xff; 0xd0; #callq *%rax
    ]
end
hook_asm_template() = (global thehook; hook_asm_template(thehook))
const hook_length = length(hook_asm_template(UInt(0)))

function hook_tail_template(extra_instructions, ret_addr)
    addr_bytes = reinterpret(UInt8,[ret_addr])
    [
    # Is this a good idea? Probably not
    extra_instructions...,
    0x66, 0x68, addr_bytes[7:8]...,
    0x66, 0x68, addr_bytes[5:6]...,
    0x66, 0x68, addr_bytes[3:4]...,
    0x66, 0x68, addr_bytes[1:2]...,
    0xc3
    ]
end

function aligned_xsave_RC()
    RCnew = Array(UInt8,length(X86_64.basic_regs)*sizeof(UInt64) +
        sizeof(fieldtype(X86_64.ExtendedRegs,:xsave_state)) + 64)

    rcptr = pointer(RCnew)
    # Align to 56 bytes (so the xsave state ends up at 64 byte alignment)
    npad = (64 - (UInt64(rcptr) % 64)) - 8
    @assert npad > 0
    rcptr += npad
    @assert (UInt64(rcptr) % 64) == 56

    RCnew, rcptr
end

# Split this out to avoid constructing a gc frame in the callback directly
@noinline function _callback(x::Ptr{Void})
    RC = X86_64.BasicRegs()
    regs = unsafe_wrap(Array, Ptr{UInt64}(x), (length(X86_64.basic_regs),), false)
    for i in X86_64.basic_regs
        set_dwarf!(RC, i, RegisterValue{UInt64}(regs[i+1], (-1%UInt64)))
    end
    xsave_ptr = Ptr{UInt8}(x+sizeof(Ptr{Void})*length(X86_64.basic_regs))
    RC = X86_64.ExtendedRegs(RC,
        unsafe_load(Ptr{fieldtype(X86_64.ExtendedRegs,:xsave_state)}(xsave_ptr)))
    hook_addr = UInt(ip(RC))-hook_length
    hook = hooks[reinterpret(Ptr{Void},hook_addr)]
    cb_RC = copy(RC)
    set_ip!(cb_RC, hook_addr+1)
    ret = hook.callback(hook, cb_RC)
    if isa(ret, Deopt)
        ret_addr = ret.addr
        extra_instructions = []
    else
        ret_addr = hook_addr+length(hook.orig_data)
        extra_instructions = hook.orig_data
    end
    resume_data = [
        #0xcc,
        resume_instructions;
        # Counteract the pushq %rip in the resume code
        0x48; 0x83; 0xc4; 0x8; # addq $8, %rsp
        hook_tail_template(extra_instructions, ret_addr)
    ]
    global callback_rwx
    callback_rwx[1:length(resume_data)] = resume_data

    # invalidate instruction cache here if ever ported to other
    # architectures

    RCnew, rcptr = aligned_xsave_RC()
    npad = UInt(rcptr - pointer(RCnew))

    # For alignment purposes
    RCnew[1:npad] = 0
    RCnew[npad+1:end] = UInt8[reinterpret(UInt8,
        UInt64[
            [get_dwarf(RC, i)[] for i in X86_64.basic_regs];
            reinterpret(UInt64,[RC.xsave_state])]);
        UInt8[0 for i = 1:(64-npad)]]

    ptr = convert(Ptr{Void},pointer(callback_rwx))::Ptr{Void}
    ptr, Ptr{UInt64}(rcptr)::Ptr{UInt64}
end
function callback(x::Ptr{Void})
    enabled = gc_enable(false)
    ptr, data = _callback(x)
    gc_enable(enabled)
    # jump to resume code
    ccall(ptr,Void,(Ptr{Void},),data)
    nothing
end

const hooking_lib = joinpath(dirname(@__FILE__),"hooking")

function __init__()
    global resume
    global thehook
    global callback_rwx
    global resume_instructions
    here = dirname(@__FILE__)
    function resume(RC)
        ccall((:hooking_jl_jumpto, hooking_lib),Void,(Ptr{UInt8},),pointer(RC.data))
    end
    theresume = cglobal((:hooking_jl_jumpto, hooking_lib), Ptr{UInt8})
    resume_instructions = unsafe_wrap(Array, convert(Ptr{UInt8}, theresume),
        (resume_length,), false)
    # Allocate an RWX page for the callback return
    callback_rwx = @static if is_apple()
        region = mach_check(mach_vm_allocate(4096)...)
        mach_check(mach_vm_protect(region,
            VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE))
        region_to_array(region)
    elseif is_linux()
        region = MemoryRegion(ccall(:mmap, Ptr{Void},
            (Ptr{Void}, Csize_t, Cint, Cint, Cint, Csize_t),
            C_NULL, 4096, PROT_EXEC | PROT_READ | PROT_WRITE,
            Base.Mmap.MAP_ANONYMOUS | Base.Mmap.MAP_PRIVATE,
            -1, 0), 4096)
        Base.systemerror("mmap", reinterpret(Int, region.addr) == -1)
        region_to_array(region)
    elseif is_windows()
        region = MemoryRegion(ccall(:VirtualAlloc, Ptr{Void},
            (Ptr{Void}, Csize_t, UInt32, UInt32),
            C_NULL, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE), 4096)
        Base.systemerror("VirtualAlloc", reinterpret(Int, region.addr) == 0)
        region_to_array(region)
    end
    thecallback = Base.cfunction(callback,Void,Tuple{Ptr{Void}})::Ptr{Void}
    ccall((:hooking_jl_set_callback, hooking_lib), Void, (Ptr{Void},),
        thecallback)
    thehook = cglobal((:hooking_jl_savecontext, hooking_lib), Ptr{UInt8})
end

# High Level Implementation

# Temporarily allow writing to an executable page.
# It would be nice to have a general version of this, but unfortunately, it
# seems the only reliable version to write something to a protected page on
# linux is to either parse the /proc mappings file or to use ptrace, neither
# of which sounds like a lot of fun. For now, just do this and assume the page
# is executable to begin with.
function allow_writing(f, region)
    # On OS X, make sure that the page is mapped as COW
    @static if is_apple()
        mach_check(mach_vm_protect(region, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE))
    elseif is_linux()
        mprotect(region, PROT_READ | PROT_WRITE | PROT_EXEC)
    elseif is_windows()
        VirtualProtect(region, PAGE_EXECUTE_READWRITE)
    end
    f()
    @static if is_apple()
        mach_check(mach_vm_protect(region, VM_PROT_EXECUTE | VM_PROT_READ))
    elseif is_linux()
        mprotect(region, PROT_READ | PROT_EXEC)
    elseif is_windows()
        VirtualProtect(region, PAGE_EXECUTE_READ)
    end
end

function determine_nbytes_to_replace(bytes_required, addr::Ptr{Void})
    triple = "x86_64-apple-darwin15.0.0"
    DC = ccall(:jl_LLVMCreateDisasm, Ptr{Void},
        (Ptr{UInt8},Ptr{Void},Cint,Ptr{Void},Ptr{Void}),
        triple, C_NULL, 0, C_NULL, C_NULL)
    @assert DC != C_NULL

    nbytes = 0
    template = hook_asm_template()
    while nbytes < bytes_required
        outs = Ref{UInt8}()
        nbytes += ccall(:jl_LLVMDisasmInstruction, Csize_t,
            (Ptr{Void}, Ptr{UInt8}, Csize_t, UInt64, Ptr{UInt8}, Csize_t),
            DC,          # Disassembler
            addr+nbytes, # bytes
            30,          # Size
            addr+nbytes, # PC
            outs, 1      # OutString
            )
    end
    
    nbytes
end
function determine_nbytes_to_replace(bytes_required, orig_bytes)
    determine_nbytes_to_replace(bytes_required, Ptr{Void}(pointer(orig_bytes)))
end

function hook(callback::Function, addr)
    # Compute number of bytes by disassembly
    # Ideally we would also check for uses of rip and branches here and error
    # out if any are found, but for now we don't need to

    template = hook_asm_template()
    nbytes = determine_nbytes_to_replace(length(template), addr)
    # Record the instructions that were there originally
    dest = unsafe_wrap(Array, convert(Ptr{UInt8}, addr), (nbytes,), false)
    orig_data = copy(dest)

    hook_asm = [ template; fill(0xcc,nbytes-length(template)) ]# Pad to nbytes
    @assert length(hook_asm) == length(orig_data)

    allow_writing(to_page(addr,nbytes)) do
        dest[:] = hook_asm
    end

    hooks[addr] = Hook(addr,orig_data,callback)
end

function hook(thehook::Hook)
    nbytes = length(thehook.orig_data)
    template = hook_asm_template();
    hook_asm = [ template; fill(0x90,nbytes-length(template)) ]# Pad to nbytes

    dest = unsafe_wrap(Array, convert(Ptr{UInt8}, thehook.addr),
        (nbytes,), false)
    allow_writing(to_page(thehook.addr,nbytes)) do
        dest[:] = hook_asm
    end

    hooks[thehook.addr] = thehook
end

function get_function_addr(t)
    llvmf = ccall(:jl_get_llvmf, Ptr{Void}, (Any, Bool, Bool), t, false, true)
    @assert llvmf != C_NULL
    fptr = ccall(:jl_get_llvm_fptr, UInt64, (Ptr{Void},), llvmf)
    @assert fptr != 0
    reinterpret(Ptr{Void},fptr)
end
get_function_addr(f, t) = get_function_addr(Tuple{typeof(f), Base.to_tuple_type(t).parameters...})


hook(callback, f, t) = hook(callback, get_function_addr(f, t))

function unhook(addr::Union{Ptr{Void},UInt64})
    hook = pop!(hooks, addr)

    nbytes = length(hook.orig_data)
    dest = unsafe_wrap(Array, convert(Ptr{UInt8}, addr),
        (nbytes,), false)

    allow_writing(to_page(addr,nbytes)) do
        dest[:] = hook.orig_data
    end
end

unhook(hook::Hook) = unhook(hook.addr)

@inline function getcontext()
    RCnew, rcptr = aligned_xsave_RC()
    ccall((:hooking_jl_simple_savecontext, hooking_lib),Void,(Ptr{UInt64},),rcptr)
    RC = X86_64.BasicRegs()
    for i in X86_64.basic_regs
        set_dwarf!(RC, i, RegisterValue{UInt64}(unsafe_load(Ptr{UInt64}(rcptr),i+1), (-1%UInt64)))
    end
    xsave_ptr = Ptr{UInt8}(rcptr+sizeof(Ptr{Void})*length(X86_64.basic_regs))
    RC = X86_64.ExtendedRegs(RC,
        unsafe_load(Ptr{fieldtype(X86_64.ExtendedRegs,:xsave_state)}(xsave_ptr)))
    RC
end

end # module
