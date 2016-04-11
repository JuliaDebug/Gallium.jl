using Gallium
using Gallium.X86_64: basic_regs, BasicRegs, dwarf_numbering
function rebuild_lib(file, oname)
    contents = readstring(file)
    for idx in basic_regs
        pat = string("UC_MCONTEXT_GREGS_",uppercase(string(dwarf_numbering[idx])))
        @show pat
        contents = replace(contents,
            pat, string(idx*sizeof(Ptr{Void})))
    end
    contents = replace(contents, "UC_MCONTEXT_SIZE", length(basic_regs)*sizeof(Ptr{Void}))
    print(contents)
    (stdout,stdin,process) = readandwrite(`$(joinpath(JULIA_HOME,"llvm-mc")) -filetype=obj - -o $oname`)
    write(stdin, contents)
    close(stdin)
    wait(process)
    println(readstring(stdout))
end

rebuild_lib("getcontext-x86_64-elf.s","elfhook.o")
rebuild_lib("jumpto-x86_64-elf.s","elfjump.o")
run(`clang -shared -o hooking.so elfjump.o elfhook.o callback.o`)
