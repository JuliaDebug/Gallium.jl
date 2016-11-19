ENV["GALLIUM_REBUILDING_HOOKING"] = "1"
using Gallium
function rebuild_lib(file, triple, oname)
    contents = readstring(file)
    replacements = collect(
        string("UC_MCONTEXT_GREGS_",uppercase(string(dwarf_numbering[idx])))=>
            string(sizeof(UInt64)*(findfirst(i->fieldname(BasicRegs,i)==dwarf_numbering[idx],1:nfields(BasicRegs))-1))
            for idx in basic_regs)
    @show replacements
    # Sort by length, to avoid replacing substrings first
    replacements = sort(replacements; by=x->length(x[1]),rev=true)
    for (pat, rep) in replacements
        contents = replace(contents, pat, rep)
    end
    basic_size = length(basic_regs)*sizeof(Ptr{Void})
    contents = replace(contents, "UC_MCONTEXT_SIZE", basic_size)
    total_size = basic_size
    if Sys.ARCH == :x86_64
        xsave_area_size = sizeof(fieldtype(Gallium.X86_64.ExtendedRegs,:xsave_state))
        total_size += xsave_area_size
    end
    contents = replace(contents, "UC_MCONTEXT_TOTAL_SIZE", total_size)
    cmd = `$(joinpath(JULIA_HOME,"../tools/llvm-mc")) -triple=$triple -filetype=obj - -o $oname`
    (stdout,stdin,process) = readandwrite(cmd)
    write(stdin, contents)
    close(stdin)
    wait(process)
    println(readstring(stdout))
end

if Sys.ARCH == :x86_64
    using Gallium.X86_64: basic_regs, BasicRegs, dwarf_numbering
    rebuild_lib("getcontext-x86_64-elf.s","x86_64-pc-linux-gnu","elfhook-x86_64.o")
    rebuild_lib("jumpto-x86_64-elf.s","x86_64-pc-linux-gnu","elfjump-x86_64.o")
    run(`clang -target x86_64-pc-linux-gnu -fPIC -c -o elf-callback-x86_64.o callback.c`)
    @linux_only run(`clang -target x86_64-pc-linux-gnu -shared -o hooking-x86_64.so elfjump-x86_64.o elfhook-x86_64.o elf-callback-x86_64.o`)

    rebuild_lib("getcontext-x86_64-macho.s","x86_64-apple-darwin15.3.0","machohook.o")
    rebuild_lib("jumpto-x86_64-macho.s","x86_64-apple-darwin15.3.0","machojump.o")
    run(`clang -target x86_64-apple-darwin15.3.0 -fPIC -c -o macho-callback.o callback.c`)
    @osx_only run(`clang -target x86_64-apple-darwin15.3.0 -shared -o hooking-x86_64.dylib machojump-x86_64.o machohook-x86_64.o macho-callback-x86_64.o`)

    windows_triple = "x86_64-pc-windows-gnu"
    rebuild_lib("getcontext-x86_64-coff.s",windows_triple,"coffhook-x86_64.o")
    rebuild_lib("jumpto-x86_64-coff.s",windows_triple,"coffjump-x86_64.o")
    run(`clang -target $windows_triple -fPIC -c -o coff-callback-x86_64.o callback.c`)
    @windows_only run(`clang -target $windows_triple -shared -o hooking-x86_64.dll coffjump-x86_64.o coffhook-x86_64.o coff-callback-x86_64.o`)
else
    using Gallium.PowerPC64: basic_regs, BasicRegs, dwarf_numbering
    rebuild_lib("getcontext-powerpc64le-elf.s","powerpc64le-unknown-linux-gnu","elfhook-powerpc64le.o")
    rebuild_lib("jumpto-powerpc64le-elf.s","powerpc64le-unknown-linux-gnu","elfjump-powerpc64le.o")
    run(`clang -target powerpc64le-unknown-linux-gnu -fPIC -c -o elf-callback-powerpc64le.o callback.c`)
    @linux_only run(`clang -target powerpc64le-unknown-linux-gnu -shared -o hooking-powerpc64le.so elfjump-powerpc64le.o elfhook-powerpc64le.o elf-callback-powerpc64le.o`)
end
