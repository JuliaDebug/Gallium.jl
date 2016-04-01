# llvm-mc -filetype=obj jumpto-x86_64-macho.s -o machojump.o
.text
.align 4,0x90
.globl _hooking_jl_jumpto
_hooking_jl_jumpto:
int $3
movq    56(%rdi), %rax # rax holds new stack pointer
subq    $16, %rax
movq    %rax, 56(%rdi)
movq    32(%rdi), %rbx  # store new rdi on new stack
movq    %rbx, 0(%rax)
movq    128(%rdi), %rbx # store new rip on new stack
movq    %rbx, 8(%rax)
# restore all registers
movq      0(%rdi), %rax
movq      8(%rdi), %rbx
movq     16(%rdi), %rcx
movq     24(%rdi), %rdx
# restore rdi later
movq     40(%rdi), %rsi
movq     48(%rdi), %rbp
# restore rsp later
movq     64(%rdi), %r8
movq     72(%rdi), %r9
movq     80(%rdi), %r10
movq     88(%rdi), %r11
movq     96(%rdi), %r12
movq    104(%rdi), %r13
movq    112(%rdi), %r14
movq    120(%rdi), %r15
# skip rflags
# skip cs
# skip fs
# skip gs
movq    56(%rdi), %rsp  # cut back rsp to new location
pop     %rdi            # rdi was saved here earlier
ret                     # rip was saved here
