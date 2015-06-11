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
#include "lldb/Initialization/InitializeLLDB.h"
#include "lldb/Core/Debugger.h"
#include "lldb/Interpreter/CommandReturnObject.h"
#include "lldb/Interpreter/CommandInterpreter.h"
#include "lldb/Breakpoint/StoppointCallbackContext.h"
"""

# LLDB Initialization
function Initialize()
    @cxx lldb_private::Initialize(cast(C_NULL,vcpp"lldb_private::LoadPluginCallbackType"))
end
__init__() = Initialize()

function debugger()
    dbg = @cxx lldb_private::Debugger::CreateInstance()
    dbg = @cxx dbg->get()
    @cxx dbg->StartEventHandlerThread()
    dbg
end

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
function ValueObjectToJulia(vo)
    if icxx"$vo->GetError().Fail();"
        error(bytestring(icxx"$vo->GetError().AsCString();"))
    end
    clangt = Cxx.QualType(icxx"$vo->GetClangType().GetOpaqueQualType();");
    if clangt.ptr == C_NULL
        error("vo does not list a type")
    end
    jt = Cxx.juliatype(clangt)
    if isbits(jt)
        @assert sizeof(jt) == @cxx vo->GetByteSize();
        data = Array(jt,1);
        icxx"""
            lldb_private::DataExtractor data;
            lldb_private::Error error;
            $vo->GetData(data,error);
            if (error.Fail()) {
                return false;
            }
            data.ExtractBytes(0,data.GetByteSize(),lldb::eByteOrderLittle,$(pointer(data)));
            return true;
        """ || error("Failed to get data")
        return data[1]
    else
        error("Unsupported")
    end
end

function _run_expr(dbg,expr,ctx = pcpp"lldb_private::ExecutionContext"(C_NULL))
    target = targets(dbg)[0]
    interpreter = ci(dbg)
    if ctx == C_NULL
        ctx = @cxx &(interpreter->GetExecutionContext())
    end
    sp = icxx"""
        lldb_private::ExecutionContext exe_ctx (*$ctx);
        lldb::ValueObjectSP result_valobj_sp;
        lldb_private::EvaluateExpressionOptions options;
        $target->EvaluateExpression($(pointer(expr)),exe_ctx.GetFramePtr(), result_valobj_sp, options);
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

end # module
