using Gallium
using Gallium.X86_64: basic_regs, BasicRegs, dwarf_numbering
function rebuild_lib(file, triple, oname)
    contents = readstring(file)
    for idx in basic_regs
        pat = string("UC_MCONTEXT_GREGS_",uppercase(string(dwarf_numbering[idx])))
        @show pat
        contents = replace(contents,
            pat, string(idx*sizeof(Ptr{Void})))
    end
    xsave_area_size = sizeof(fieldtype(Gallium.X86_64.ExtendedRegs,:xsave_state))
    basic_size = length(basic_regs)*sizeof(Ptr{Void})
    contents = replace(contents, "UC_MCONTEXT_SIZE", basic_size)
    contents = replace(contents, "UC_MCONTEXT_TOTAL_SIZE", xsave_area_size + basic_size)
    print(contents)
    cmd = `$(joinpath(JULIA_HOME,"../tools/llvm-mc")) -triple=$triple -filetype=obj - -o $oname`
    (stdout,stdin,process) = readandwrite(cmd)
    write(stdin, contents)
    close(stdin)
    wait(process)
    println(readstring(stdout))
end

rebuild_lib("getcontext-x86_64-elf.s","x86_64-pc-linux-gnu","elfhook.o")
rebuild_lib("jumpto-x86_64-elf.s","x86_64-pc-linux-gnu","elfjump.o")
run(`clang -target x86_64-pc-linux-gnu -fPIC -c -o elf-callback.o callback.c`)
@linux_only run(`clang -target x86_64-pc-linux-gnu -shared -o hooking.so elfjump.o elfhook.o elf-callback.o`)

rebuild_lib("getcontext-x86_64-macho.s","x86_64-apple-darwin15.3.0","machohook.o")
rebuild_lib("jumpto-x86_64-macho.s","x86_64-apple-darwin15.3.0","machojump.o")
run(`clang -target x86_64-apple-darwin15.3.0 -fPIC -c -o macho-callback.o callback.c`)
@osx_only run(`clang -target x86_64-apple-darwin15.3.0 -shared -o hooking.dylib machojump.o machohook.o macho-callback.o`)

windows_triple = "x86_64-pc-windows-gnu"
rebuild_lib("getcontext-x86_64-coff.s",windows_triple,"coffhook.o")
rebuild_lib("jumpto-x86_64-coff.s",windows_triple,"coffjump.o")
run(`clang -target $windows_triple -fPIC -c -o coff-callback.o callback.c`)
@windows_only run(`clang -target $windows_triple -shared -o hooking.dll coffjump.o coffhook.o coff-callback.o`)
