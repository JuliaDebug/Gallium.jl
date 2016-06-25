using Gallium
using Gallium.Hooking
using Base.Test

addr = cglobal(:jl_)
# Test error return
Hooking.hook(addr) do hook, RC
    error()
end

@test_throws ErrorException ccall(:jl_,Void,(Any,),addr)

Hooking.unhook(addr)

# Should not throw anymore
ccall(:jl_,Void,(Any,),Hooking.hook)

# Now test proper return
didrun = false
Hooking.hook(addr) do hook, RC
    global didrun = true
end
ccall(:jl_,Void,(Any,),Hooking.hook)
@test didrun

bigfib(n) = ((BigInt[1 1; 1 0])^n)[2,1]

Hooking.hook(bigfib, Tuple{Int}) do hook, RC
    for ip in Gallium.rec_backtrace(RC)
        @show (ccall(:jl_lookup_code_address, Any, (Ptr{Void}, Cint),
            reinterpret(Ptr{Void},ip-1), 0))[1]
    end
end
bigfib(20)

@test !Hooking.mem_validate(0,sizeof(Ptr{Void}))
x = Array(UInt8,sizeof(Ptr{Void}))
@test Hooking.mem_validate(pointer(x),sizeof(Ptr{Void}))
@test length(x) == sizeof(Ptr{Void})
