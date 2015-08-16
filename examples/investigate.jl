include("call.jl")
using Cxx
using DIDebug
using ObjFileBase
using MachO

eval(Base,:(have_color = true))

function ReadObjectFile(objfile)
    osize = icxx"$(objfile)->GetByteSize();"
    data = Array(UInt8,osize)
    icxx"$(objfile)->CopyData(0,$osize,$(pointer(data)));"
    buf = IOBuffer(data)
    oh = readmeta(buf)
end

objcache = Dict{Any,Any}()

function Base.print(io::IO,frame::Union{pcpp"lldb_private::StackFrame",
                                    cxxt"lldb::StackFrameSP"})
  if Gallium.isJuliaFrame(frame)
    print(io,getFrameDescription(frame))
  else
    print(io,Gallium.dump(frame))
  end
end

# Memoized DIInfo processing
function processed_cus(frame::Union{pcpp"lldb_private::StackFrame",
                                    cxxt"lldb::StackFrameSP"})
    block = icxx"$frame->GetFrameBlock();"
    if block == C_NULL
        error(sprint(print,frame))
    end
    mod = icxx"$frame->GetFrameBlock()->CalculateSymbolContextModule();"
    id = Gallium.uuid(mod)
    if !haskey(objcache,id)
        oh = ReadObjectFile(icxx"$mod->GetObjectFile();")
        debugoh = ReadObjectFile(icxx"$mod->GetSymbolVendor()->
                GetSymbolFile()->GetObjectFile();")
        dbgs = debugsections(debugoh);
        strtab = load_strtab(dbgs.debug_str)
        objcache[id] = (oh, dbgs, DIDebug.process_cus(dbgs, strtab))
    end
    objcache[id]
end
function_name(frame::cxxt"lldb::StackFrameSP") =
    bytestring(icxx"$frame->GetFrameBlock()->CalculateSymbolContextFunction()->GetName();")

ctx = Gallium.ctx(dbg)
thread = Gallium.current_thread(ctx)
for frame in thread
    if icxx"$frame->GetFrameBlock();" == C_NULL
        continue
    end
    oh, dbgs, didata = try
        processed_cus(frame)
    catch e
        @show e
        continue
    end
    name = function_name(frame)
    @show name
    DIDebug.investigate_function(oh, dbgs, didata, name)
end
