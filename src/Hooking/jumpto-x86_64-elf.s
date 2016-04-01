# cpp jumpto-x86_64-elf.s | ~/julia-debugger/usr/bin/llvm-mc -filetype=obj - -o elfjump.o
#include "x86-64-mregs.inc"

.text
.align 4,0x90
.globl hooking_jl_jumpto
hooking_jl_jumpto:
nop
movq    UC_MCONTEXT_GREGS_RSP(%rdi), %rax # rax holds new stack pointer
subq    $16, %rax
movq    %rax, UC_MCONTEXT_GREGS_RSP(%rdi)
movq    UC_MCONTEXT_GREGS_RDI(%rdi), %rbx # store new rdi on new stack
movq    %rbx, 0(%rax)
movq    UC_MCONTEXT_GREGS_RIP(%rdi), %rbx # store new rip on new stack
movq    %rbx, 8(%rax)
# restore all registers
movq     UC_MCONTEXT_GREGS_RAX(%rdi), %rax
movq     UC_MCONTEXT_GREGS_RBX(%rdi), %rbx
movq     UC_MCONTEXT_GREGS_RCX(%rdi), %rcx
movq     UC_MCONTEXT_GREGS_RDX(%rdi), %rdx
# restore rdi later
movq     UC_MCONTEXT_GREGS_RSI(%rdi), %rsi
movq     UC_MCONTEXT_GREGS_RBP(%rdi), %rbp
# restore rsp later
movq     UC_MCONTEXT_GREGS_R8(%rdi), %r8
movq     UC_MCONTEXT_GREGS_R9(%rdi), %r9
movq     UC_MCONTEXT_GREGS_R10(%rdi), %r10
movq     UC_MCONTEXT_GREGS_R11(%rdi), %r11
movq     UC_MCONTEXT_GREGS_R12(%rdi), %r12
movq     UC_MCONTEXT_GREGS_R13(%rdi), %r13
movq     UC_MCONTEXT_GREGS_R14(%rdi), %r14
movq     UC_MCONTEXT_GREGS_R15(%rdi), %r15
# skip rflags
# skip cs
# skip fs
# skip gs
movq    UC_MCONTEXT_GREGS_RSP(%rdi), %rsp  # cut back rsp to new location
pop     %rdi            # rdi was saved here earlier
ret                     # rip was saved here
