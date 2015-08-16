include("call.jl")
using TerminalUI
using Cxx
using Reactive
using DIDebug
using ObjFileBase
using MachO

eval(Base,:(have_color = true))

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
function Base.print(io::IO,frame::Union{pcpp"lldb_private::StackFrame",
                                    cxxt"lldb::StackFrameSP"})
  if Gallium.isJuliaFrame(frame)
    print(io,getFrameDescription(frame))
  else
    print(io,Gallium.dump(frame))
  end
end

####################

function ReadObjectFile(objfile)
    osize = icxx"$(objfile)->GetByteSize();"
    data = Array(UInt8,osize)
    icxx"$(objfile)->CopyData(0,$osize,$(pointer(data)));"
    buf = IOBuffer(data)
    oh = readmeta(buf)
end

objcache = Dict{Any,Any}()

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

#####################

function Base.print(io::IO,V::Union{pcpp"lldb_private::Variable",
                                    cxxt"lldb::VariableSP"})
    print(io,Gallium.dump(V))
end

thread = Gallium.current_thread(ctx)
listw = Border(ListWidget(thread),"Stack Frame")
VL = icxx"$(thread[7])->GetVariableList(false);"
listw2 = ListWidget(VL)
w3 = IOBufferView(IOBuffer())
lift(listw.child.highlighted) do it
    VL = icxx"$(thread[it])->GetVariableList(false);"
    if VL != C_NULL
      listw2.item = VL
    else
      listw2.item = ("No Local Variables",)
    end
    listw2.cur_top = start(listw2.item)
    TerminalUI.invalidate(listw2)
end
lift(listw.child.highlighted) do it
    frame = thread[it]
    buf = IOBuffer()
    try
        oh, dbgs, didata = processed_cus(frame)
        name = function_name(frame)
        DIDebug.investigate_function(buf, oh, dbgs, didata, name)
    catch e
        print(buf,e)
    end
    w3.buf = buf
    w3.cur_top = TerminalUI.element_start(w3)
    TerminalUI.invalidate(w3)
end
b2 = Border(listw2,"Local Variables")
b3 = Border(w3,"Current Function")
tty = Base.Terminals.TTYTerminal("xterm",STDIN,STDOUT,STDERR)
wait(FullScreenDialog(WidgetStack(reverse([b3,listw,b2])),tty))
