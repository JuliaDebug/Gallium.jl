function lookup_global(dbg,name)
    target = targets(dbg)[0]
    @assert target != C_NULL
    ectx = ctx(dbg)
    VL = icxx"
        m_vl.Clear();
        $target->GetImages().FindGlobalVariables(lldb_private::ConstString($(pointer(name))),true,1,m_vl);
        &m_vl;
    "
    V = first(VL)
    TargetValue(icxx" lldb_private::ValueObjectVariable::Create($ectx.GetBestExecutionContextScope(), $V); ")
end

function lookup_function(dbg, name)
    target = targets(dbg)[0]
    @assert target != C_NULL
    ectx = Gallium.ctx(dbg)
    lookup_function(target, ectx, name)
end

function lookup_function(target, ectx, name)
    SCL = icxx"""
        const bool append = true;
        const bool symbols_ok = true;
        const bool inlines_ok = true;
        m_scl.Clear();
        $target->GetImages().FindFunctions (
                                  lldb_private::ConstString($(pointer(name))),
                                  lldb::eFunctionNameTypeBase,
                                  symbols_ok,
                                  inlines_ok,
                                  append,
                                  m_scl);
        &m_scl;
    """
    S = first(SCL)
end

getFunctionCallAddress(dbg,sctx) = getFunctionCallAddress(targets(dbg)[0],sctx)
function getFunctionCallAddress(target::Union{pcpp"lldb_private::Target",
                                              vcpp"lldb::TargetSP"},sctx)
    icxx"""
        lldb_private::AddressRange range;
        $sctx.GetAddressRange(lldb::eSymbolContextFunction,0,false,range);
        range.GetBaseAddress().GetCallableLoadAddress($target);
    """
end

function callFunction(dbg, name, argnames)
    faddr = getFunctionCallAddress(dbg, lookup_function(dbg, name))
    argaddrs = [addr(lookup_global(dbg, aname)) for aname in argnames]
    ectx = ctx(dbg)
    CreateCallFunctionPlan(Cxx.instance(TargetClang),
        Cxx.extractTypePtr(Cxx.cpptype(Cxx.instance(TargetClang), Void)),
        ectx, faddr, argaddrs)
end

function call( ::Type{TargetValue},
              VO::Union{pcpp"lldb_private::ValueObject",
                        vcpp"lldb_private::ValueObject",
                        pcpp"lldb_private::ValueObjectVariable",
                        vcpp"lldb_private::ValueObjectVariable"})
    JV = ValueObjectToJulia(VO)
end
function call( ::Type{TargetValue}, JV)
    if isa(JV,pcpp"_jl_lambda_info_t")
        return TargetLambda(convert(UInt64,JV.ptr))
    elseif isa(JV,pcpp"_jl_module_t")
        return TargetModule(TargetRef(convert(UInt64,JV.ptr)))
    elseif isa(JV,pcpp"_jl_value_t")
        return TargetRef(convert(UInt64,JV.ptr))
    elseif typeof(JV) <: Cxx.CppPtr
        return TargetPtr{typeof(JV)}(convert(UInt64,JV.ptr))
    elseif isa(JV,Ptr)
        return TargetPtr{typeof(JV).parameters[1]}(convert(UInt64,JV))
    else
        return TargetCxxVal{typeof(JV)}(JV)
    end
end

call( ::Type{TargetValue}, VO::cxxt"lldb::ValueObjectSP") = call(TargetValue, icxx"$VO.get();")

function lookup_sym(mod::TargetModule,sym)

end
