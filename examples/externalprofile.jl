const data = UInt[]
function create_lidict(target, data)
    udata = unique(data)
    lidict = Dict{UInt,Base.Profile.LineInfo}()
    for addr in udata
        if addr == 0
            continue
        end
        icxx"""
            lldb_private::Address addr;
            $target->ResolveLoadAddress($addr,addr);
            auto module = addr.GetModule();
            auto *function = addr.CalculateSymbolContextFunction();
            lldb_private::LineEntry line_entry;
            addr.CalculateSymbolContextLineEntry(line_entry);
            $:(begin
                funcnameptr = icxx"return function;" != C_NULL ?
                    icxx"return function->GetName().GetCString();" : C_NULL
                funcname = funcnameptr == C_NULL ? "???" :
                    bytestring(funcnameptr)
                filenameptr =  icxx"return !line_entry.file;" ?
                    C_NULL : icxx"return line_entry.file.GetFilename();"
                filename = filenameptr == C_NULL ? "???" :
                    bytestring(filenameptr)
                isjl = icxx"return module.get();" != C_NULL ?
                    !Gallium.isJuliaModule(icxx"return module;") :
                    true;
                line = icxx"return line_entry.line;"
                lidict[addr] = Base.Profile.LineInfo(
                funcname, filename, line,
                "", # For now, easy to do correctly
                0,
                isjl,
                reinterpret(Int64,addr))
                nothing
            end);
        """
    end
    lidict
end
function callback(env, ctx, id, loc)
    ctx = pcpp"lldb_private::StoppointCallbackContext"(ctx)
    exe_ctx = icxx"&$ctx->exe_ctx_ref;"
    process = icxx"$exe_ctx->GetProcessSP();"
    target = icxx"$exe_ctx->GetTargetSP().get();"
    profiler_thread = icxx"$exe_ctx->GetThreadSP();"
    tlist = icxx"$process->GetThreadList();"
    append!(data,map(frame->icxx"$frame->GetFrameCodeAddress().GetLoadAddress($target);",tlist[0]))
    push!(data,0)
    # Skip the rest of the data collection on the profiler thread
    Gallium.JumpToLine(profiler_thread,"signals-apple.c",295)
    return false
end
SetBreakpointAtLoc(callback,targets(dbg)[0],"signals-apple.c",238)
#=
using ProfileView
lidict = create_lidict(targets(dbg)[0],data)
ProfileView.view(data,C=true,lidict=lidict)
=#
