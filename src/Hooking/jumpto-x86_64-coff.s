# cpp jumpto-x86_64-elf.s | ~/julia-debugger/usr/bin/llvm-mc -filetype=obj - -o elfjump.o

.text
.align 4,0x90
.globl hooking_jl_jumpto
hooking_jl_jumpto:
nop
# Restore FP and SSE state (RFBM = 0b11)
movq $3, %rax
xor %rdx, %rdx
xrstor  UC_MCONTEXT_SIZE(%rcx)
movq    UC_MCONTEXT_GREGS_RSP(%rcx), %rax # rax holds new stack pointer
subq    $16, %rax
movq    %rax, UC_MCONTEXT_GREGS_RSP(%rcx)
movq    UC_MCONTEXT_GREGS_RCX(%rcx), %rbx  # store new rcx on new stack
movq    %rbx, 0(%rax)
movq    UC_MCONTEXT_GREGS_RIP(%rcx), %rbx # store new rip on new stack
movq    %rbx, 8(%rax)
# restore all registers
movq     UC_MCONTEXT_GREGS_RAX(%rcx), %rax
movq     UC_MCONTEXT_GREGS_RBX(%rcx), %rbx
# restore rcx later
movq     UC_MCONTEXT_GREGS_RCX(%rcx), %rcx
movq     UC_MCONTEXT_GREGS_RDX(%rcx), %rdx
movq     UC_MCONTEXT_GREGS_RDI(%rcx), %rsi
movq     UC_MCONTEXT_GREGS_RSI(%rcx), %rsi
movq     UC_MCONTEXT_GREGS_RBP(%rcx), %rbp
# restore rsp later
movq     UC_MCONTEXT_GREGS_R8(%rcx), %r8
movq     UC_MCONTEXT_GREGS_R9(%rcx), %r9
movq     UC_MCONTEXT_GREGS_R10(%rcx), %r10
movq     UC_MCONTEXT_GREGS_R11(%rcx), %r11
movq     UC_MCONTEXT_GREGS_R12(%rcx), %r12
movq     UC_MCONTEXT_GREGS_R13(%rcx), %r13
movq     UC_MCONTEXT_GREGS_R14(%rcx), %r14
movq     UC_MCONTEXT_GREGS_R15(%rcx), %r15
# skip rflags
# skip cs
# skip fs
# skip gs
movq    UC_MCONTEXT_GREGS_RSP(%rcx), %rsp  # cut back rsp to new location
pop     %rcx            # rcx was saved here earlier
ret                     # rip was saved here
