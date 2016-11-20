# cpp getcontext-x86_64-elf.s | ~/julia-debugger/usr/bin/llvm-mc -filetype=obj - -o elfhook.o
# Saves registers in a stack buffer in the order that the
# platform convention requires, then calls a callback passing
# the address of the stack buffer as that function's first
# argument.

.include "getcontext-x86_64-generic.S"

.align 4,0x90
.globl hooking_jl_savecontext
.type hooking_jl_savecontext, @function
hooking_jl_savecontext:
SAVE_GPREGS
DO_XSAVE buf=%rsp

movq    %rsp,    %rdi

# Align stack for call
subq    $8, %rsp
pushq   %rsi           # Makes the debugger's life easier
movq hooking_jl_callback@GOTPCREL(%rip), %rax
jmpq *(%rax)

.text
.align 4,0x90
.globl hooking_jl_savecontext_legacy
.type hooking_jl_savecontext_legacy, @function
hooking_jl_savecontext_legacy:
SAVE_GPREGS
DO_FXSAVE buf=%rsp

movq    %rsp,    %rdi

# Align stack for call
subq    $8, %rsp
pushq   %rsi           # Makes the debugger's life easier
movq hooking_jl_callback@GOTPCREL(%rip), %rax
jmpq *(%rax)

.text
.align 4,0x90
.globl hooking_jl_simple_savecontext
hooking_jl_simple_savecontext:
SAVE_GPREGS_SIMPLE
DO_XSAVE buf=%rdi

retq

.text
.align 4,0x90
.globl hooking_jl_simple_savecontext_legacy
hooking_jl_simple_savecontext_legacy:
SAVE_GPREGS_SIMPLE
DO_FXSAVE buf=%rdi

retq

.section	.note.GNU-stack,"",@progbits
