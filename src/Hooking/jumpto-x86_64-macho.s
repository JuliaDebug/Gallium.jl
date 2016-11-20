# llvm-mc -filetype=obj jumpto-x86_64-macho.s -o machojump.o

.include "jumpto-x86_64-generic.S"

.text
.align 4,0x90
.globl hooking_jl_jumpto
.type hooking_jl_jumpto,@function
hooking_jl_jumpto:
nop
XSAVE_RESTORE buf=%rdi
RESTORE_GPREGS_AND_JMP_SYSV

.text
.align 4,0x90
.globl hooking_jl_jumpto_legacy
.type hooking_jl_jumpto_legacy,@function
hooking_jl_jumpto_legacy:
nop
FXSAVE_RESTORE buf=%rdi
RESTORE_GPREGS_AND_JMP_SYSV

.subsections_via_symbols
