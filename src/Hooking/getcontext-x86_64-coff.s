# cpp getcontext-x86_64-elf.s | ~/julia-debugger/usr/bin/llvm-mc -filetype=obj - -o elfhook.o
# Saves registers in a stack buffer in the order that the
# platform convention requires, then calls a callback passing
# the address of the stack buffer as that function's first
# argument.

.include "getcontext-x86_64-generic.S"

.text
.align 4,0x90
.globl hooking_jl_savecontext
hooking_jl_savecontext:
SAVE_GPREGS
DO_XSAVE buf=%rsp

movq    %rsp,    %rcx

# Align stack for call
subq    $8, %rsp
pushq   %rsi           # Makes the debugger's life easier
movq hooking_jl_callback@GOTPCREL(%rip), %rax
jmpq *%rax

.text
.align 4,0x90
.globl hooking_jl_simple_savecontext
hooking_jl_simple_savecontext:
SAVE_GPREGS_SIMPLE buf=%rcx
DO_XSAVE buf=%rcx
retq

.text
.align 4,0x90
.globl hooking_jl_savecontext_legacy
hooking_jl_savecontext_legacy:
SAVE_GPREGS
DO_FXSAVE buf=%rsp

movq    %rsp,    %rcx

# Align stack for call
subq    $8, %rsp
pushq   %rsi           # Makes the debugger's life easier
movq hooking_jl_callback@GOTPCREL(%rip), %rax
jmpq *%rax

.text
.align 4,0x90
.globl hooking_jl_simple_savecontext_legacy
hooking_jl_simple_savecontext_legacy:
SAVE_GPREGS_SIMPLE buf=%rcx
DO_FXSAVE buf=%rcx
retq
