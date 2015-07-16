import CxxREPL

function AddExternalToInstance(C::Cxx.CxxInstance, dbg, decl_map)
    target = targets(dbg)[0]
    icxx"$target->GetClangModulesDeclVendor();" == C_NULL || error("Unimplemented")
    icxx"""
    if ($decl_map)
    {
        clang::ASTContext *ast_context = $(instance(C).CI)->getASTContext();
        llvm::IntrusiveRefCntPtr<clang::ExternalASTSource> ast_source(decl_map->CreateProxy());
        decl_map->InstallASTContext(ast_context);
        ast_context->setExternalSource(ast_source);
    }
    """
end

function ClangASTType(C, T)
    icxx" lldb_private::ClangASTType{&$(C.CI)->getASTContext(), clang::QualType($T,0)}; "
end

function CreateCallFunctionPlan(C, rt, ectx, start_addr, arguments::Vector{UInt64} = UInt64[])
    error_stream = icxx"lldb_private::StreamString{};"
    if isa(rt,Cxx.QualType)
        rt = Cxx.extractTypePtr(rt)
    end
    rt = icxx"""
        if (isa<clang::AutoType>($rt))
            return cast<clang::AutoType>($rt)->desugar().getTypePtr();
        else
            return const_cast<const clang::Type*>($rt);
    """
    VO = icxx"""
        lldb_private::StreamString &error_stream = $error_stream;
        lldb_private::ExecutionContext &ctx = $ectx;
        if (!ctx.HasThreadScope())
        {
            $:(error("Execute called with no thread selected."));
        }

        lldb_private::EvaluateExpressionOptions options;

        lldb_private::Address address ($start_addr);
        llvm::ArrayRef <lldb::addr_t> args((lldb::addr_t*)$(pointer(arguments)),$(endof(arguments)));
        //llvm::ArrayRef <lldb::addr_t> args;

        lldb::ThreadPlanSP call_plan_sp(new lldb_private::ThreadPlanCallFunction(ctx.GetThreadRef(), address, $(ClangASTType(C,rt)), args, options));

        if (!call_plan_sp || !call_plan_sp->ValidatePlan (&error_stream))
            $:(error("Plan Creation Failed"));

        lldb::ExpressionResults execution_result = ctx.GetProcessRef().RunThreadPlan (ctx,
                                                                                   call_plan_sp,
                                                                                   options,
                                                                                   error_stream);
        if (execution_result != 0)
            $:(error(bytestring(error_stream)));

        return call_plan_sp->GetReturnValueObject();
    """
    #ValueObjectToJulia(icxx"$VO.get();")
end

function CreateCallFunctionPlan(C, rt, ectx, start_addr, arguments = UInt64[])
    error_stream = icxx"lldb_private::StreamString{};"
    if isa(rt,Cxx.QualType)
        rt = Cxx.extractTypePtr(rt)
    end
    rt = icxx"""
        if (isa<clang::AutoType>($rt))
            return cast<clang::AutoType>($rt)->desugar().getTypePtr();
        else
            return const_cast<const clang::Type*>($rt);
    """
    VO = icxx"""
        lldb_private::StreamString &error_stream = $error_stream;
        lldb_private::ExecutionContext &ctx = $ectx;
        if (!ctx.HasThreadScope())
        {
            $:(error("Execute called with no thread selected."));
        }

        lldb_private::EvaluateExpressionOptions options;

        lldb_private::Address address ($start_addr);
        llvm::SmallVector <lldb::addr_t, 6> args;
        size_t nargs = $(endof(arguments));
        for (size_t i = 0; i < nargs; ++i) {
            $:(
            arg = arguments[icxx"i;"]
            if isa(arg, Cxx.CxxBuiltinTypes)
                icxx"args.push_back(ABI::CallArgument(.type = TargetValue, .size = $(sizeof(arg)), .value = $(convert(UInt64,arg))));"
            else
                icxx"args.push_back(ABI::CallArgument(.type = HostPointer, .size = $(sizeof(arg)), .value = $(pointer(arg))));"
            end);
        }

        //llvm::ArrayRef <lldb::addr_t> args;

        lldb::ThreadPlanSP call_plan_sp(new lldb_private::ThreadPlanCallFunction(ctx.GetThreadRef(), address, $(ClangASTType(C,rt)), args, options));

        if (!call_plan_sp || !call_plan_sp->ValidatePlan (&error_stream))
            $:(error("Plan Creation Failed"));

        lldb::ExpressionResults execution_result = ctx.GetProcessRef().RunThreadPlan (ctx,
                                                                                   call_plan_sp,
                                                                                   options,
                                                                                   error_stream);
        if (execution_result != 0)
            $:(error(bytestring(error_stream)));

        return call_plan_sp->GetReturnValueObject();
    """
    #ValueObjectToJulia(icxx"$VO.get();")
end

const llvmctx = icxx" std::shared_ptr<llvm::LLVMContext>{&jl_LLVMContext}; "

function newModule(name)
    icxx"""
        auto m = new llvm::Module($(pointer(name)), jl_LLVMContext);
        m->setDataLayout(jl_ExecutionEngine->getDataLayout()->getStringRepresentation());
        m->setTargetTriple(jl_TargetMachine->getTargetTriple().str());
        m;
    """
end

function RunModule(C, dbg, mod, F, rt; arguments = UInt64[])
    name = bytestring(icxx"$F->getName();")
    str = icxx"lldb_private::ConstString{$(pointer(name))};"
    IREU = icxx"""
        std::vector<std::string> empty_string_list(0);
        std::unique_ptr<llvm::Module> modptr{$mod};
        new lldb_private::IRExecutionUnit($llvmctx,modptr,$str,$dbg->GetTargetList().GetTargetAtIndex(0),empty_string_list);
    """
    @assert IREU != C_NULL
    addr = icxx"""
    lldb_private::Error err;
    lldb::addr_t func_addr, func_end;
    $IREU->GetRunnableInfo(err,func_addr,func_end);
    if (err.Fail()) {
        std::cout << err.AsCString() << "\n";
        $:(error("Failed to get runnable"));
    }
    func_addr;
    """
    @assert addr != -1
    CreateCallFunctionPlan(C, rt, Gallium.ctx(dbg), addr, arguments)
end

function CreateTargetFunction(body)
    C = Cxx.instance(Gallium.TargetClang)
    Decl, _, _ = Cxx.CreateFunctionWithBody(C,string("{\n",body,"\n}"))
    rt = Cxx.GetFunctionReturnType(pcpp"clang::FunctionDecl"(Decl.ptr))
    llvmf = pcpp"llvm::Function"(Cxx.GetAddrOfFunction(C,Decl).ptr)
    llvmf, rt
end

function CallTargetBody(dbg, body)
    target_shadow = Cxx.instance(Gallium.TargetClang).shadow
    target_module = Gallium.newModule("test")
    F, rt = CreateTargetFunction(body)
    icxx"""
    FunctionMover2 mover2($target_module);
    MapFunction($F, &mover2);
    """
    Gallium.RunModule(Cxx.instance(Gallium.TargetClang), dbg,
        target_module, F, Cxx.extractTypePtr(rt))
end

function makeOnDone(dbg)
    function simpleOnDone(C)
        function (line)
            toplevel = CxxREPL.isTopLevelExpression(C,line)
            @show toplevel
            if toplevel
                Cxx.process_cxx_string(string(line,"\n;"), toplevel,
                    false, :REPL, 1, 1; compiler = C)
            else
                VOp = CallTargetBody(dbg, line)
                if icxx"$VOp.get();" == C_NULL
                    return nothing
                end
                return ValueObjectToJulia(icxx"$VOp.get();")
            end
        end
    end
end

function RunTargetREPL(dbg)
    CxxREPL.RunCxxREPL(Gallium.TargetClang; name = :targetcxx,
        prompt = "Target C++ > ", key = '>', onDoneCreator = makeOnDone(dbg))
end
