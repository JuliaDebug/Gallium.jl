# cpp getcontext-x86_64-elf.s | ~/julia-debugger/usr/bin/llvm-mc -filetype=obj - -o elfhook.o
# Saves registers in a stack buffer in the order that the
# platform convention requires, then calls a callback passing
# the address of the stack buffer as that function's first
# argument.

#include "x86-64-mregs.inc"

.text
.align 4,0x90
.globl hooking_jl_savecontext
hooking_jl_savecontext:
nop
subq    $UC_MCONTEXT_SIZE,    %rsp
# Get rax from one above the stack pointer
# (caller's responsibility to save)
movq    (UC_MCONTEXT_SIZE+8)(%rsp),%rax
movq    %rax, UC_MCONTEXT_GREGS_RAX(%rsp)
movq    %rbx, UC_MCONTEXT_GREGS_RBX(%rsp)
movq    %rcx, UC_MCONTEXT_GREGS_RCX(%rsp)
movq    %rdx, UC_MCONTEXT_GREGS_RDX(%rsp)
movq    %rdi, UC_MCONTEXT_GREGS_RDI(%rsp)
movq    %rsi, UC_MCONTEXT_GREGS_RSI(%rsp)
movq    %rbp, UC_MCONTEXT_GREGS_RBP(%rsp)
movq    %rsp, UC_MCONTEXT_GREGS_RSP(%rsp)
addq    $(UC_MCONTEXT_SIZE+16), UC_MCONTEXT_GREGS_RSP(%rsp)
movq    %r8,  UC_MCONTEXT_GREGS_R8(%rsp)
movq    %r9,  UC_MCONTEXT_GREGS_R9(%rsp)
movq    %r10, UC_MCONTEXT_GREGS_R10(%rsp)
movq    %r11, UC_MCONTEXT_GREGS_R11(%rsp)
movq    %r12, UC_MCONTEXT_GREGS_R12(%rsp)
movq    %r13, UC_MCONTEXT_GREGS_R13(%rsp)
movq    %r14, UC_MCONTEXT_GREGS_R14(%rsp)
movq    %r15, UC_MCONTEXT_GREGS_R15(%rsp)
movq    UC_MCONTEXT_SIZE(%rsp),%rsi
movq    %rsi, UC_MCONTEXT_GREGS_RIP(%rsp) # store return address as rip
movq    %rsp,    %rdi
pushq   %rsi           # Makes the debugger's life easier
movq hooking_jl_callback@GOTPCREL(%rip), %rax
jmpq *(%rax)
