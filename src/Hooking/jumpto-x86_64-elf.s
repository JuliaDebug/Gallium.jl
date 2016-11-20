# cpp jumpto-x86_64-elf.s | ~/julia-debugger/usr/bin/llvm-mc -filetype=obj - -o elfjump.o

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


.section	.note.GNU-stack,"",@progbits
