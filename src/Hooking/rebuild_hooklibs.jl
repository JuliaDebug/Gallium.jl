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
    contents = replace(contents, "UC_MCONTEXT_SIZE", length(basic_regs)*sizeof(Ptr{Void}))
    print(contents)
    (stdout,stdin,process) = readandwrite(`$(joinpath(JULIA_HOME,"llvm-mc")) -triple= -filetype=obj - -o $oname`)
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
