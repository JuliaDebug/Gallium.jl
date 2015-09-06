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

function registerASTContext(ctx)
    icxx"""
        auto clang_ast_ctx = new lldb_private::ClangASTContext;
        clang_ast_ctx->setASTContext($ctx);
    """
end

function ClangASTType(C, T)
    if icxx" lldb_private::ClangASTContext::GetASTContext(&$(C.CI)->getASTContext()) == NULL; "
        registerASTContext(icxx"&$(C.CI)->getASTContext();")
    end
    CT = icxx" lldb_private::CompilerType{&$(C.CI)->getASTContext(), clang::QualType($T,0)}; "
    @assert icxx" $CT.IsValid(); "
    CT
end

#=
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
        options.SetDebug(false);
        options.SetUnwindOnError(false);
        options.SetIgnoreBreakpoints(true);
        options.SetTryAllThreads(false);
        options.SetOneThreadTimeoutUsec();
        options.SetTimeoutUsec();

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
    ValueObjectToJulia(icxx"$VO.get();")
end
=#

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
        error_stream.Write("Hello",5);
        lldb_private::ExecutionContext &ctx = $ectx;
        if (!ctx.HasThreadScope())
        {
            $:(error("Execute called with no thread selected."));
        }

        lldb_private::EvaluateExpressionOptions options;
        options.SetDebug(false);
        options.SetUnwindOnError(false);
        options.SetIgnoreBreakpoints(true);
        options.SetTryAllThreads(false);
        options.SetOneThreadTimeoutUsec();
        options.SetTimeoutUsec();

        lldb_private::Address address ($start_addr);
        llvm::SmallVector <lldb_private::ABI::CallArgument, 6> args;
        size_t nargs = $(endof(arguments));
        for (size_t i = 1; i <= nargs; ++i) {
            $:(begin
              arg = arguments[icxx"return i;"]
              if isa(arg, Gallium.TargetCxxVal)
                  arg = arg.val
              end
              if isa(arg, Cxx.CxxBuiltinTypes) || isa(arg,Ptr) || isa(arg,Cxx.CppPtr)
                  icxx"args.push_back(
                    lldb_private::ABI::CallArgument{
                      .type = lldb_private::ABI::CallArgument::TargetValue,
                      .size = static_cast<size_t>($(sizeof(arg))),
                      .value = $(convert(UInt64,arg))});"
              else
                  icxx"
                    size_t argsize = $(sizeof(arg));
                    std::unique_ptr<uint8_t[]> data_ap{new uint8_t[argsize]};
                    memcpy(data_ap.get(),$(pointer(arg)),argsize);
                    args.push_back(lldb_private::ABI::CallArgument{
                      .type = lldb_private::ABI::CallArgument::HostPointer,
                      .size = argsize, .data_ap = std::move(data_ap)});
                  "
              end
            end);
        }

        //llvm::ArrayRef <lldb::addr_t> args;

        llvm::Type *TVoid = $(Cxx.julia_to_llvm(Void));
        lldb::ThreadPlanSP call_plan_sp(
          new lldb_private::ThreadPlanCallFunctionUsingABI(
            ctx.GetThreadRef(), address, *TVoid, $(ClangASTType(C,rt)), args, options));

        if (!call_plan_sp || !call_plan_sp->ValidatePlan (&error_stream))
            $:(error("Plan Creation Failed"));

        call_plan_sp->SetIsMasterPlan(true);
        call_plan_sp->SetOkayToDiscard(false);

        lldb::ExpressionResults execution_result = ctx.GetProcessRef().RunThreadPlan (ctx,
                                                                                   call_plan_sp,
                                                                                   options,
                                                                                   error_stream);
        if (execution_result != 0) {
            $:(error(string("Got error (",icxx"return execution_result;","): ",
              bytestring(error_stream))));
        }

        return call_plan_sp->GetReturnValueObject();
    """
    ValueObjectToJulia(icxx"$VO.get();")
end

const llvmctx = icxx" std::shared_ptr<llvm::LLVMContext>{&jl_LLVMContext}; "

function newModule(name)
    icxx"""
        auto m = new llvm::Module($(pointer(name)), jl_LLVMContext);
        m->setDataLayout(jl_ExecutionEngine->getDataLayout().getStringRepresentation());
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

function CreateTargetFunction(Decl::pcpp"clang::Decl")
    C = Cxx.instance(Gallium.TargetClang)
    rt = Cxx.GetFunctionReturnType(pcpp"clang::FunctionDecl"(Decl.ptr))
    llvmf = pcpp"llvm::Function"(Cxx.GetAddrOfFunction(C,Decl).ptr)
    llvmf, rt
end

function CreateTargetFunction(body::AbstractString)
    CreateTargetFunction(Cxx.CreateFunctionWithBody(Cxx.instance(Gallium.TargetClang),string("{\n",body,"\n}"))[1])
end

function CallTargetBody(dbg, body; arguments = Any[])
    target_shadow = Cxx.instance(Gallium.TargetClang).shadow
    target_module = Gallium.newModule("test")
    F, rt = CreateTargetFunction(body)
    icxx"""
    FunctionMover2 mover2($target_module);
    MapFunction($F, &mover2);
    """
    Gallium.RunModule(Cxx.instance(Gallium.TargetClang), dbg,
        target_module, F, Cxx.extractTypePtr(rt); arguments = arguments)
end

function makeOnDone(dbg)
    function simpleOnDone(C)
        function (line)
            line = string(line,"\n;")
            toplevel = CxxREPL.isTopLevelExpression(C,line)
            if toplevel
                Cxx.process_cxx_string(string(line,"\n;"), toplevel,
                    false, :REPL, 1, 1; compiler = C)
            else
                startvarnum, sourcebuf, exprs, isexprs, icxxs =
                Cxx.process_body(C,line,false,:REPL,1,1)
                source = takebuf_string(sourcebuf)
                args = Expr(:tuple,exprs...)
                quote
                    t = $args
                    decl,_,_ = Cxx.CreateFunctionWithBody(Cxx.instance($C),$source,typeof(t).parameters...)
                    return Gallium.CallTargetBody($dbg, decl; arguments = Any[t...])
                end
            end
        end
    end
end

function RunTargetREPL(dbg)
    CxxREPL.RunCxxREPL(Gallium.TargetClang; name = :targetcxx,
        prompt = "Target C++ > ", key = '>', onDoneCreator = makeOnDone(dbg))
end

function target_call(dbg::pcpp"lldb_private::Debugger",sym,args)
    ectx = Gallium.ctx(dbg)
    target = targets(dbg)[0]
    _target_call(target,ectx,sym,args)
end

function target_call(frame,sym,args)
    ectx = getExecutionContextForFrame(frame)
    target = getTargetForFrame(frame)
    _target_call(target,ectx,sym,args)
end

function _target_call(target,ectx,sym,args)
    F = Gallium.lookup_function(target,ectx,string(sym))
    faddr = Gallium.getFunctionCallAddress(target,F)
    FTy = getFunctionType(F)
    RT = Cxx.getFTyReturnType(FTy)
    C = Cxx.instance(Gallium.TargetClang)
    if isa(args, Vector{UInt64})
        Gallium.CreateCallFunctionPlan(C, RT, ectx, faddr, args)
    else
        Gallium.CreateCallFunctionPlan(C, RT, ectx, faddr, args)
    end
end

#=
size_t
ReadMemory (const Address& addr,
            bool prefer_file_cache,
            void *dst,
            size_t dst_len,
            Error &error,
            lldb::addr_t *load_addr_ptr = NULL);
=#

target_read(dbg::pcpp"lldb_private::Debugger",ptr,size) =
  target_read(targets(dbg)[0],ptr,size)
function target_read(target, ptr, size)
    data = Array(UInt8,size)
    icxx"""
      lldb_private::Error error;
      $target->GetProcessSP()->DoReadMemory($ptr, $(pointer(data)), $size, error);
      if (error.Fail())
          $:(error(bytestring(icxx"return error.AsCString();")));
    """
    return data
end
