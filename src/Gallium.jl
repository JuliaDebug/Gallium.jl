module Gallium

export Initialize, debugger, SetOutputFileHandle, SetErrorFileHandle, platforms, targets,
    GetCommandInterpreter, HandleCommand, lldb_exec, ValueObjectToJulia, run_expr, SetBreakpoint,
    SetBreakpointAtLoc

using Cxx

# General LLVM Headers
include(Pkg.dir("Cxx","test","llvmincludes.jl"))

# LLDB Headers
cxx"""
#define LLDB_DISABLE_PYTHON
#include "lldb/API/SystemInitializerFull.h"
#include "lldb/Initialization/SystemLifetimeManager.h"
#include "llvm/Support/ManagedStatic.h"
#include "lldb/Core/Debugger.h"
#include "lldb/Core/Module.h"
#include "lldb/Interpreter/CommandReturnObject.h"
#include "lldb/Interpreter/CommandInterpreter.h"
#include "lldb/Breakpoint/StoppointCallbackContext.h"
#include "lldb/Target/StackFrame.h"
#include "lldb/Target/Thread.h"
#include "lldb/Target/ThreadPlanCallFunction.h"
#include "lldb/Symbol/VariableList.h"
#include "lldb/Symbol/Variable.h"
#include "lldb/Symbol/Block.h"
#include "lldb/Symbol/CompileUnit.h"
#include "lldb/Symbol/ClangASTType.h"
#include "lldb/Core/ValueObject.h"
#include "lldb/Core/ValueObjectVariable.h"
#include "lldb/Expression/ClangModulesDeclVendor.h"
#include "lldb/Expression/IRExecutionUnit.h"
#include "llvm/AsmParser/Parser.h"
static llvm::ManagedStatic<lldb_private::SystemLifetimeManager> g_debugger_lifetime;
llvm::LLVMContext &jl_LLVMContext = llvm::getGlobalContext();
extern "C" {
    extern void jl_error(const char *str);
}
extern llvm::ExecutionEngine *jl_ExecutionEngine;
extern llvm::TargetMachine *jl_TargetMachine;
"""

cxxinclude(Pkg.dir("DIDebug","src","FunctionMover.cpp"))

# LLDB Initialization
cxx"""
void gallium_error_handler(void *user_data, const std::string &reason, bool gen_crash_diag)
{
    $:(error(bytestring(icxx"return reason.data();",icxx"return reason.size();")));
}
"""
Initialize() = icxx"g_debugger_lifetime->Initialize(llvm::make_unique<lldb_private::SystemInitializerFull>(), nullptr);"
function __init__()    Initialize()
    # LLDB's error handler isn't very useful.
    icxx"
        remove_fatal_error_handler();
        //install_fatal_error_handler(gallium_error_handler);
"
end

function debugger()
    dbg = @cxx lldb_private::Debugger::CreateInstance()
    dbg = @cxx dbg->get()
    @cxx dbg->StartEventHandlerThread()
    dbg
end


# Create a clang instance
TargetClang = Cxx.new_clang_instance()

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
            @cxx l->($GetSize)()
        end

        Base.start(l::$T) = 0
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
ValueObjectToJulia(vo::Union(vcpp"lldb_private::ValueObject",vcpp"lldb_private::ValueObjectVariable")) =
    ValueObjectToJulia(icxx"&$vo;")
function ValueObjectToJulia(vo::Union(pcpp"lldb_private::ValueObject",
                        pcpp"lldb_private::ValueObjectVariable"))
    @assert vo != C_NULL
    if icxx"$vo->GetError().Fail();"
        error(bytestring(icxx"$vo->GetError().AsCString();"))
    end
    clangt = Cxx.QualType(icxx"$vo->GetClangType().GetOpaqueQualType();");
    if clangt.ptr == C_NULL
        error("vo does not list a type")
    end
    jt = Cxx.juliatype(clangt)
    if isbits(jt)
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
        return data[1]
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

function current_thread(ctx)
    icxx"$ctx.GetThreadPtr();"
end

function getModuleForFrame(frame)
    block = icxx"$frame->GetFrameBlock();"
    if block != C_NULL
        return icxx"$block->CalculateSymbolContextModule();"
    else
        return C_NULL
    end
end

const DW_LANG_JULIA = 31
function isJuliaModule(M::pcpp"lldb_private::Module")
    icxx"$(first(M))->GetLanguage();" == DW_LANG_JULIA
end
isJuliaModule(M::ModuleSP) = isJuliaModule(icxx"$M.get();")

function isJuliaFrame(frame::pcpp"lldb_private::StackFrame")
    mod = getModuleForFrame(frame)
    mod == C_NULL && return false
    isJuliaModule(mod)
end
isJuliaFrame(frame::StackFrameSP) = isJuliaFrame(icxx"$frame.get();")


function printJuliaStackFrame(frame)

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
addr(x::TargetPtr) = x.ptr

cxx"""
    lldb_private::VariableList m_vl;
    lldb_private::SymbolContextList m_scl;
"""

include("cxxinterop.jl")
include("target.jl")

function remote_lookup(sym)
    jl_get_binding(jl_main_module, sym)
end

end # module
