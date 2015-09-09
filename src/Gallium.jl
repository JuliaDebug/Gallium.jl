module Gallium

export Initialize, debugger, SetOutputFileHandle, SetErrorFileHandle, platforms, targets,
    GetCommandInterpreter, HandleCommand, lldb_exec, ValueObjectToJulia, run_expr, SetBreakpoint,
    SetBreakpointAtLoc, current_thread

using Cxx
using TerminalUI

# General LLVM Headers
include(Pkg.dir("Cxx","test","llvmincludes.jl"))

# LLDB Headers
cxx"""
#define LLDB_DISABLE_PYTHON
#include <iostream>
#include "lldb/API/SystemInitializerFull.h"
#include "lldb/Initialization/SystemLifetimeManager.h"
#include "llvm/Support/ManagedStatic.h"
#include "lldb/Core/Debugger.h"
#include "lldb/Core/Module.h"
#include "lldb/Core/Section.h"
#include "lldb/Interpreter/CommandObject.h"
#include "lldb/Interpreter/CommandReturnObject.h"
#include "lldb/Interpreter/CommandInterpreter.h"
#include "lldb/Breakpoint/StoppointCallbackContext.h"
#include "lldb/Target/StackFrame.h"
#include "lldb/Target/Thread.h"
#include "lldb/Target/ThreadPlanCallFunction.h"
#include "lldb/Target/ThreadPlanStepInRange.h"
#include "lldb/Target/ThreadPlanCallFunctionUsingABI.h"
#include "lldb/Target/ABI.h"
#include "lldb/Target/UnixSignals.h"
#include "lldb/Host/ThreadLauncher.h"
#include "lldb/Symbol/SymbolVendor.h"
#include "lldb/Symbol/SymbolFile.h"
#include "lldb/Symbol/VariableList.h"
#include "lldb/Symbol/Variable.h"
#include "lldb/Symbol/Block.h"
#include "lldb/Symbol/CompileUnit.h"
#include "lldb/Symbol/Type.h"
#include "lldb/Symbol/Function.h"
#include "lldb/Core/ValueObject.h"
#include "lldb/Core/ValueObjectVariable.h"
#include "lldb/Expression/ClangModulesDeclVendor.h"
#include "lldb/Expression/IRExecutionUnit.h"
#include "llvm/AsmParser/Parser.h"
static llvm::ManagedStatic<lldb_private::SystemLifetimeManager> g_debugger_lifetime;
"""

cxxinclude(Pkg.dir("DIDebug","src","FunctionMover.cpp"))
cxxinclude(joinpath(dirname(@__FILE__),"EventHandler.cpp"))
include("JuliaStream.jl")

# LLDB Initialization
cxx"""
void gallium_error_handler(void *user_data, const std::string &reason, bool gen_crash_diag)
{
    $:(error(bytestring(icxx"return reason.data();",icxx"return reason.size();")));
}
"""
Initialize() = icxx"g_debugger_lifetime->Initialize(llvm::make_unique<lldb_private::SystemInitializerFull>(), nullptr);"
function __init__()
    Initialize()
    # LLDB's error handler isn't very useful.
    icxx"""
        remove_fatal_error_handler();
        //install_fatal_error_handler(gallium_error_handler);
    """
end

function debugger()
    dbg = icxx"lldb_private::Debugger::CreateInstance().get();"
    writableend = Base.PipeEndpoint()
    readableend = Base.PipeEndpoint()
    loop = icxx"""
        auto loop = new uv_loop_t;
        uv_loop_init(loop);
        return loop;
    """.ptr
    Base.init_pipe!(writableend; writable = true, loop = loop)
    Base.init_pipe!(readableend; readable = true, loop = Base.eventloop())
    Base._link_pipe(readableend.handle, writableend.handle)
    readableend.status = Base.StatusOpen
    icxx"""
        auto h = new JuliaEventHandler($dbg);
        h->StartJuliaEventHandlerThread();
        lldb::IOHandlerSP io_handler_sp (new IOHandlerGallium (*$dbg));
        if (io_handler_sp)
        {
            $dbg->PushIOHandler(io_handler_sp);
        }
        $dbg->SetOutputStream(std::shared_ptr<lldb_private::Stream>{
            new UvPipeStream((uv_pipe_t*)$(writableend.handle))});
    """
    writableend.handle = C_NULL
    term = Base.Terminals.TTYTerminal("",STDIN,STDOUT,STDERR)
    @async while !eof(readableend)
        const CSI = TerminalUI.CSI
        line = strip(readline(readableend),'\n')
        w = Base.LineEdit.width(term)
        ns = div(max(0,strwidth(line)-1),w)+1
        print(STDOUT,string("$(CSI)s",
                            "$(CSI)",ns,"A",
                            "$(CSI)",ns,"S",
                            "$(CSI)",ns,"L",
                            "$(CSI)1G",
                            line,
                            "$(CSI)u"))
    end
    initialize_commands(GetCommandInterpreter(dbg))
    dbg
end

# Create a clang instance
TargetClang = Cxx.new_clang_instance(false)

# Constants
const eLazyBoolCalculate = cast(Int32(-1),vcpp"lldb_private::LazyBool")
const eLazyBoolNo        = cast(UInt32(0),vcpp"lldb_private::LazyBool")
const eLazyBoolYes       = cast(UInt32(1),vcpp"lldb_private::LazyBool")

SetOutputFileHandle(dbg, fh::Libc.FILE, transfer_ownership) =
    @cxx dbg->SetOutputFileHandle(pcpp"FILE"(fh.ptr), transfer_ownership)

SetErrorFileHandle(dbg, fh::Libc.FILE, transfer_ownership) =
    @cxx dbg->SetErrorFileHandle(pcpp"FILE"(fh.ptr), transfer_ownership)

# Handy Accessors
function _lldb_list(T,GetSize)
    quote
        function Base.length(l::$T)
            @assert l != C_NULL
            @cxx l->($GetSize)()
        end
        Base.endof(l::$T) = length(l)

        Base.start(l::$T) = 0
        Base.prevind(l::$T,i::Int) = i-1
        Base.next(l::$T,i) = (l[i],i+1)
        Base.done(l::$T,i) = i >= length(l)
    end
end

macro _lldb_list(T, GetSize)
    esc(_lldb_list(T,GetSize))
end

macro lldb_list(T, GetSize, GetIdx)
    esc(quote
        $(_lldb_list(T,GetSize))
        function Base.getindex(l::$T, idx)
            @assert l != C_NULL
            if idx > length(l)
                throw(BoundsError())
            end
            @cxx l->($GetIdx)(idx)
        end
    end)
end

macro lldb_sp_list(T,GetSize,GetIdx)
    esc(quote
        $(_lldb_list(T,GetSize))
        function Base.getindex(l::$T, idx)
            if idx > length(l)
                throw(BoundsError())
            end
            @cxx (@cxx l->($GetIdx)(idx))->get()
        end
    end)
end

function platforms(dbg)
    @cxx dbg->GetPlatformList()
end

function targets(dbg)
    @cxx dbg->GetTargetList()
end

import Base: length, getindex
@lldb_sp_list rcpp"lldb_private::ThreadList" GetSize GetThreadAtIndex
@lldb_sp_list rcpp"lldb_private::TargetList" GetNumTargets GetTargetAtIndex
@lldb_list rcpp"lldb_private::PlatformList" GetSize GetAtIndex
@lldb_list vcpp"lldb_private::FileSpecList" GetSize GetFileSpecPointerAtIndex

# Interactivity Support
GetCommandInterpreter(dbg::pcpp"lldb_private::Debugger") = @cxx dbg->GetCommandInterpreter()
function HandleCommand(ci, cmd)
    cro = @cxx lldb_private::CommandReturnObject()
    @cxx ci->HandleCommand(pointer(cmd),eLazyBoolNo,cro)
    if !@cxx cro->Succeeded()
        error(bytestring(@cxx cro->GetErrorData()))
    end
    @cxx cro->GetOutputData()
end

function lldb_exec(dbg,p)
    bytestring(HandleCommand(GetCommandInterpreter(dbg),p))
end

# Expression Support
function retrieveData(vo,jt)
    @assert sizeof(jt) == icxx"$vo->GetByteSize();";
    data = Array(jt,1);
    icxx"""
        lldb_private::DataExtractor data;
        lldb_private::Error error;
        $vo->GetData(data,error);
        if (error.Fail()) {
            return false;
        }
        data.ExtractBytes(0,data.GetByteSize(),lldb::eByteOrderLittle,$(convert(Ptr{Void},pointer(data))));
        return true;
    """ || error("Failed to get data")
    data[1]
end

ValueObjectToJulia(vo::Union(vcpp"lldb_private::ValueObject",vcpp"lldb_private::ValueObjectVariable")) =
    ValueObjectToJulia(icxx"&$vo;")
function ValueObjectToJulia(vo::Union(pcpp"lldb_private::ValueObject",
                        pcpp"lldb_private::ValueObjectVariable"))
    @assert vo != C_NULL
    if icxx"$vo->GetError().Fail();"
        error(bytestring(icxx"$vo->GetError().AsCString();"))
    end
    clangt = Cxx.QualType(icxx"$vo->GetCompilerType().GetOpaqueQualType();");
    if clangt.ptr == C_NULL
        error("vo does not list a type")
    end
    jt = Cxx.juliatype(clangt)
    if isbits(jt)
        return retrieveData(vo,jt)
    elseif jt === Any
        return TargetRef(retrieveData(vo,UInt64))
    else
        error("Unsupported")
    end
end

function _run_expr(dbg,expr,ctx = pcpp"lldb_private::ExecutionContext"(C_NULL))
    target = targets(dbg)[0]
    interpreter = GetCommandInterpreter(dbg)
    if ctx == C_NULL
        ctx = icxx"$interpreter.GetExecutionContext();"
    end
    sp = icxx"""
        lldb::ValueObjectSP result_valobj_sp;
        lldb_private::EvaluateExpressionOptions options;
        $target->EvaluateExpression($(pointer(expr)),$ctx.GetFramePtr(), result_valobj_sp, options);
        return result_valobj_sp;
    """
    sp
end

function run_expr(dbg,expr,ctx = pcpp"lldb_private::ExecutionContext"(C_NULL))
    sp = _run_expr(dbg,expr,ctx)
    val = ValueObjectToJulia(@cxx sp->get())
    @cxx sp->reset()
    val
end

const user_id_t = UInt32

# Registers

macro reg_ctx(T)
    quote
        @lldb_list $T GetRegisterCount GetRegisterInfoAtIndex
    end
end

@reg_ctx pcpp"RegisterContextMemory"

function Base.show(reg::cpcpp"lldb_private::RegisterInfo")
    print("RegisterInfo(name=")
    name = @cxx reg->name
    show(name == C_NULL ? "NULL" : bytestring(name))
    println(")")
end

# Breakpoints
function SetCallback(bc,func)
    icxx"""
    $bc->SetCallback(
        (lldb_private::BreakpointHitCallback)
        $(cfunction(func,Bool,
            (Ptr{Void},Ptr{Void},user_id_t,user_id_t))),
        nullptr);
    """
    @cxx bc->ResolveBreakpoint()
end

function SetBreakpointAtLoc(func,target,file,line)
    bc = icxx"""
    lldb_private::FileSpecList A;
    lldb_private::FileSpec filespec($(pointer(file)),false);
    $target->CreateBreakpoint(&A,filespec,$line,lldb_private::eLazyBoolCalculate,lldb_private::eLazyBoolYes,false,false).get();
    """
    SetCallback(bc,func)
    bc
end

function SetBreakpoint(func,target,point)
    bc = icxx"""
    lldb_private::FileSpecList A,B;
    $target->CreateBreakpoint(&A,&B,$(pointer(point)),lldb::eFunctionNameTypeAuto,lldb_private::eLazyBoolYes,false,false).get();
    """
    SetCallback(bc,func)
    bc
end

# Dumping Various data structures

import Base: bytestring
function bytestring(s::vcpp"lldb_private::StreamString")
    icxx"$s.Flush();"
    bytestring(icxx"$s.GetData();",icxx"$s.GetSize();")
end

function bytestring(s::Union(vcpp"lldb_private::ConstString",
                             rcpp"lldb_private::ConstString"))
    bytestring(icxx"$s.GetCString();",icxx"$s.GetLength();")
end

function bytestring(s::vcpp"llvm::StringRef")
    bytestring(icxx"$s.data();",icxx"$s.size();")
end

function dump(SF::pcpp"lldb_private::StackFrame")
    @assert SF != C_NULL
    s = icxx"lldb_private::StreamString{};"
    icxx"$SF->Dump(&$s,false,false);"
    bytestring(s)
end
dump(x::cxxt"lldb::StackFrameSP") = dump(icxx"$x.get();")

function dump(VL::pcpp"lldb_private::VariableList")
    @assert VL != C_NULL
    s = icxx"lldb_private::StreamString{};"
    icxx"$VL->Dump(&$s,false);"
    bytestring(s)
end

function dump(V::pcpp"lldb_private::Variable")
    @assert V != C_NULL
    s = icxx"lldb_private::StreamString{};"
    icxx"$V->Dump(&$s,false);"
    bytestring(s)
end
dump(V::cxxt"lldb::VariableSP") = dump(icxx"$V.get();")

function dump(B::pcpp"lldb_private::Block")
    @assert B != C_NULL
    s = icxx"lldb_private::StreamString{};"
    icxx"$B->DumpSymbolContext(&$s);"
    bytestring(s)
end

function dump(M::pcpp"lldb_private::Module")
    @assert M != C_NULL
    s = icxx"lldb_private::StreamString{};"
    icxx"$M->Dump(&$s);"
    bytestring(s)
end
const ModuleSP = cxxt"lldb::ModuleSP"
const StackFrameSP = cxxt"lldb::StackFrameSP"
dump(M::ModuleSP) = dump(icxx"$M.get();")

@lldb_list pcpp"lldb_private::VariableList" GetSize GetVariableAtIndex
@lldb_list pcpp"lldb_private::Thread" GetStackFrameCount GetStackFrameAtIndex
@lldb_list pcpp"lldb_private::Module" GetNumCompileUnits GetCompileUnitAtIndex
@lldb_list pcpp"lldb_private::Function" GetArgumentCount GetArgumentTypeAtIndex
@_lldb_list pcpp"lldb_private::SymbolContextList" GetSize

getindex(SCL::pcpp"lldb_private::SymbolContextList", idx) = icxx" (*$SCL)[$idx]; "

function ctx(dbg)
    target = targets(dbg)[0]
    interpreter = GetCommandInterpreter(dbg)
    icxx"$interpreter.GetExecutionContext();"
end

function current_frame(ctx)
    icxx"$ctx.GetFramePtr();"
end

current_frame(ctx::pcpp"lldb_private::ExecutionContext") =
    icxx"$ctx->GetFramePtr();"

function current_thread(ctx)
    icxx"$ctx.GetThreadPtr();"
end

current_thread(ctx::pcpp"lldb_private::ExecutionContext") =
    icxx"$ctx->GetThreadPtr();"

function getModuleForFrame(frame)
    icxx"$frame->GetSymbolContext(lldb::eSymbolContextModule).module_sp.get();"
end

function getTargetForFrame(frame)
    return icxx"$frame->CalculateTarget().get();"
end

function getFunctionForFrame(frame)
    block = icxx"$frame->GetFrameBlock();"
    if block != C_NULL
        return icxx"$block->CalculateSymbolContextFunction();"
    else
        return pcpp"lldb_private::Function"(C_NULL)
    end
end

function getExecutionContextForFrame(frame)
    icxx"""
        lldb_private::ExecutionContext ctx;
        $frame->CalculateExecutionContext(ctx);
        ctx;
    """
end

function getFunctionName(F)
    if F == C_NULL
        return "unknown"
    else
        bytestring(icxx"$F->GetName();")
    end
end

const DW_LANG_JULIA = 31
function isJuliaModule(M::pcpp"lldb_private::Module")
    icxx"$(first(M))->GetLanguage();" == DW_LANG_JULIA
end
isJuliaModule(M::ModuleSP) = isJuliaModule(icxx"$M.get();")

function isJuliaFrame(frame::pcpp"lldb_private::StackFrame", include_jlcall=false)
    mod = getModuleForFrame(frame)
    mod == C_NULL && return false
    ret = isJuliaModule(mod)
    ret || return ret
    if !include_jlcall
        ret &= !startswith(getFunctionName(getFunctionForFrame(frame)),"jlcall")
    end
end
isJuliaFrame(frame::StackFrameSP,include_jlcall=false) = isJuliaFrame(icxx"$frame.get();")

mod(frame) = icxx"$frame->GetSymbolContext (lldb::eSymbolContextModule).module_sp;"

function demangle_name(name)
  first = findfirst(name,'_')
  last = findlast(name,'_')
  name[(first+1):(last-1)]
end

function getASTForFrame(frame)
    mod = getModuleForFrame(frame)
    mod == C_NULL && error("Failed to get module")
    name = bytestring(icxx"return $mod->GetFileSpec().GetFilename();")
    F = getFunctionForFrame(frame)
    if contains(name, "JIT")
        name = getFunctionName(F)
        li = target_call(frame,:jl_function_for_symbol, [string(name,'\0')])
    else
        target = getTargetForFrame(frame)
        addr = icxx"$F->GetAddressRange().GetBaseAddress().GetLoadAddress($target);"
        li = target_call(frame,:jl_lookup_li, UInt64[addr])
    end
    li
end

getFunctionType(sc::rcpp"lldb_private::SymbolContext") =
  getFunctionType(icxx"$sc.function;")
function getFunctionType(F::pcpp"lldb_private::Function")
    @assert F != C_NULL
    Cxx.QualType(icxx"$F->GetCompilerType().GetOpaqueQualType();")
end

function printJuliaStackFrame(frame)
    Base.print_with_color(:blue,
      demangle_name(getFunctionName(getFunctionForFrame(frame))))
    println()
end

abstract TargetValue

immutable TargetRef <: TargetValue
    ref::UInt64
end
addr(x::TargetRef) = x.ref

immutable TargetModule <: TargetValue
    mod::TargetRef
end
TargetModule(mod::UInt64) = TargetModule(TargetRef(mod))
addr(x::TargetModule) = addr(x.mod)

immutable TargetPtr{T} <: TargetValue
    ptr::UInt64
end
function Cxx.cpptype{T}(C,x::Type{Gallium.TargetPtr{T}})
    @assert C == Cxx.instance(Gallium.TargetClang)
    T <: Cxx.CppPtr ? Cxx.cpptype(C,T) : Cxx.cpptype(C,Ptr{T})
end
Base.convert(::Type{UInt64}, val::TargetPtr) = val.ptr
addr(x::TargetPtr) = x.ptr

immutable TargetLambda <: TargetValue
    ptr::UInt64
end

immutable TargetCxxVal{T} <: TargetValue
    val::T
end
Cxx.cpptype{T}(C,x::Type{Gallium.TargetCxxVal{T}}) = (@assert C == Cxx.instance(Gallium.TargetClang); Cxx.cpptype(C,T))
Base.convert(::Type{UInt64}, val::TargetCxxVal) = Base.convert(UInt64, val.val)

cxx"""
    lldb_private::VariableList m_vl;
    lldb_private::SymbolContextList m_scl;
"""

include("cxxinterop.jl")
include("target.jl")
include("targetrepl.jl")
include("commands.jl")

function remote_lookup(sym)
    jl_get_binding(jl_main_module, sym)
end

immutable UUID{N}
    data::NTuple{N,UInt8}
end

function Base.call{N}(::Type{UUID{N}},ptr::Ptr)
    data = Ref{UUID{N}}()
    ccall(:memcpy,Void,(Ref{UUID{N}},Ptr{UInt8},Csize_t),data,ptr,N)
    data[]
end

function uuid(mod::Union{pcpp"lldb_private::Module",
                         cxxt"lldb::ModuleSP"})
    N = icxx"$mod->GetUUID().GetByteSize();"
    ptr = icxx"$mod->GetUUID().GetBytes();"
    UUID{convert(Int,N)}(ptr)
end

Base.convert(::Type{UInt64},x::Cxx.CppPtr) = Base.convert(UInt64,x.ptr)

end # module
