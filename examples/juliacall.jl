using Cxx
include(Pkg.dir("Gallium","examples","call.jl"))
entrypoint = Gallium.entrypoint_for_julia_expression(dbg,"f","""
buf = IOBuffer()
Base.print_specialized_signature(buf,f)
takebuf_string(buf)
""")
lldb_exec(dbg,"f 7")
lldb_exec(dbg,"f 7")
ctx = Gallium.ctx(dbg)
function getFrameDescription(frame)
  li = Gallium.getASTForFrame(frame).ptr
  str = Gallium.call_prepared_entrypoint(dbg, ctx, entrypoint, Ptr{Void}[li])
  ptr = Gallium.target_call(dbg,:jl_bytestring_ptr,[str.ptr])
  size = Gallium.target_call(dbg,:jl_bytestring_length,[str.ptr])
  bytestring(Gallium.target_read(dbg,convert(UInt64,ptr),size))
end
thread = Gallium.current_thread(ctx)
for frame in thread
    Gallium.isJuliaFrame(frame) || continue
    println(getFrameDescription(frame))
end
