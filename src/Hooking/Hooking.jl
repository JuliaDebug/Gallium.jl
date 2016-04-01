module Hooking

typealias MachTask Ptr{Void}
typealias KernReturn UInt32

immutable MemoryRegion
    @osx_only task::MachTask
    addr::Ptr{Void}
    size::UInt64
end

region_to_array(region::MemoryRegion) =
    pointer_to_array(convert(Ptr{UInt8}, region.addr), (region.size,), false)

# mach vm wrappers
@osx_only begin

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

@linux_only begin
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

# Register save implementation

@osx_only const RegisterMap = Dict(
    :rsp => 8,
    :rip => 17
)

@linux_only const RegisterMap = Dict(
    :rip => div(UC_MCONTEXT_GREGS_RIP,sizeof(Ptr{Void}))+1,
    :rsp => div(UC_MCONTEXT_GREGS_RSP,sizeof(Ptr{Void}))+1
)

@osx_only const RC_SIZE = 20*8
@linux_only const RC_SIZE = 0xb0

immutable RegisterContext
    data::Array{UInt}
end
RegisterContext() = RegisterContext(Array(UInt,RC_SIZE))
Base.copy(RC::RegisterContext) = RegisterContext(copy(RC.data))
get_ip(RC::RegisterContext) = RC.data[RegisterMap[:rip]]-14

# Actual hooking

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

# The text section of jumpto-x86_64-macho.o
@osx_only const resume_length = 91
@linux_only const resume_length = 0x71

# Split this out to avoid constructing a gc frame in the callback directly
@noinline function _callback(x::Ptr{Void})
    RC = RegisterContext(reinterpret(UInt,
        copy(pointer_to_array(convert(Ptr{UInt8}, x), (RC_SIZE,), false))))
    hook_addr = RC.data[RegisterMap[:rip]]-14
    hook = hooks[reinterpret(Ptr{Void},hook_addr)]
    ret = hook.callback(hook, copy(RC))
    if isa(ret, Deopt)
        ret_addr = ret.addr
        extra_instructions = []
    else
        ret_addr = hook_addr+length(hook.orig_data)
        extra_instructions = hook.orig_data
    end
    addr_bytes = reinterpret(UInt8,[ret_addr])
    resume_data = [
        resume_instructions...,
        # Counteract the pushq %rip in the resume code
        0x48, 0x83, 0xc4, 0x8, # addq $8, %rsp
        # Is this a good idea? Probably not
        extra_instructions...,
        0x66, 0x68, addr_bytes[7:8]...,
        0x66, 0x68, addr_bytes[5:6]...,
        0x66, 0x68, addr_bytes[3:4]...,
        0x66, 0x68, addr_bytes[1:2]...,
        0xc3
    ]
    global callback_rwx
    callback_rwx[1:length(resume_data)] = resume_data

    # invalidate instruction cache here if ever ported to other
    # architectures

    ptr = convert(Ptr{Void},pointer(callback_rwx))::Ptr{Void}
    ptr, pointer(RC.data)::Ptr{UInt64}
end
function callback(x::Ptr{Void})
    ptr, data = _callback(x)
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
    function resume(RC::RegisterContext)
        ccall((:hooking_jl_jumpto, hooking_lib),Void,(Ptr{UInt8},),pointer(RC.data))
    end
    theresume = cglobal((:hooking_jl_jumpto, hooking_lib), Ptr{UInt8})
    resume_instructions = pointer_to_array(convert(Ptr{UInt8}, theresume),
        (resume_length,), false)
    # Allocate an RWX page for the callback return
    @osx_only callback_rwx = begin
        region = mach_check(mach_vm_allocate(4096)...)
        mach_check(mach_vm_protect(region,
            VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE))
        region_to_array(region)
    end
    @linux_only callback_rwx = begin
        region = MemoryRegion(ccall(:mmap, Ptr{Void},
            (Ptr{Void}, Csize_t, Cint, Cint, Cint, Csize_t),
            C_NULL, 4096, PROT_EXEC | PROT_READ | PROT_WRITE,
            Base.Mmap.MAP_ANONYMOUS | Base.Mmap.MAP_PRIVATE,
            -1, 0), 4096)
        Base.systemerror("mmap", reinterpret(Int, region.addr) == -1)
        region_to_array(region)
    end
    ccall((:hooking_jl_set_callback, hooking_lib), Void, (Ptr{Void},),
        Base.cfunction(callback,Void,Tuple{Ptr{Void}})::Ptr{Void})
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
    @osx_only mach_check(
        mach_vm_protect(region, VM_PROT_READ | VM_PROT_WRITE))
    @linux_only mprotect(region, PROT_READ | PROT_WRITE | PROT_EXEC)
    f()
    @osx_only mach_check(
        mach_vm_protect(region, VM_PROT_EXECUTE | VM_PROT_READ))
    @linux_only mprotect(region, PROT_READ | PROT_EXEC)
end

function hook(callback::Function, addr)
    # Compute number of bytes by disassembly
    # Ideally we would also check for uses of rip and branches here and error
    # out if any are found, but for now we don't need to
    triple = "x86_64-apple-darwin15.0.0"
    DC = ccall(:jl_LLVMCreateDisasm, Ptr{Void},
        (Ptr{UInt8},Ptr{Void},Cint,Ptr{Void},Ptr{Void}),
        triple, C_NULL, 0, C_NULL, C_NULL)
    @assert DC != C_NULL


    hook_asm_template = [
        0x90; #0xcc;
        0x50; #pushq   %rax
        # movq $hookto, %rax
        0x48; 0xb8; reinterpret(UInt8, [thehook]);
        0xff; 0xd0; #callq *%rax
    ]

    nbytes = 0
    while nbytes < length(hook_asm_template)
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

    # Record the instructions that were there originally
    dest = pointer_to_array(convert(Ptr{UInt8}, addr), (nbytes,), false)
    orig_data = copy(dest)

    hook_asm = [ hook_asm_template; zeros(UInt8,nbytes-length(hook_asm_template)) ]# Pad to nbytes

    allow_writing(to_page(addr,nbytes)) do
        dest[:] = hook_asm
    end

    hooks[addr] = Hook(addr,orig_data,callback)
end

function get_function_addr(f, t)
    t = Tuple{typeof(f), Base.to_tuple_type(t).parameters...}
    llvmf = ccall(:jl_get_llvmf, Ptr{Void}, (Any, Any, Bool, Bool), f, t, false, true)
    @assert llvmf != C_NULL
    reinterpret(Ptr{Void},ccall(:jl_get_llvm_fptr, UInt64, (Ptr{Void},), llvmf))
end

hook(callback, f, t) = hook(callback, get_function_addr(f, t))

function unhook(addr)
    hook = pop!(hooks, addr)

    nbytes = length(hook.orig_data)
    dest = pointer_to_array(convert(Ptr{UInt8}, addr),
        (nbytes,), false)

    allow_writing(to_page(addr,nbytes)) do
        dest[:] = hook.orig_data
    end
end

end # module
