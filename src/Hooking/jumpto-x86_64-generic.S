.macro RESTORE_GPREGS_AND_JMP_SYSV
movq    UC_MCONTEXT_GREGS_RSP(%rdi), %rax # rax holds new stack pointer
subq    $16, %rax
movq    %rax, UC_MCONTEXT_GREGS_RSP(%rdi)
movq    UC_MCONTEXT_GREGS_RDI(%rdi), %rbx  # store new rdi on new stack
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
.endm

.macro XSAVE_RESTORE buf=%rdi
# Restore FP and SSE state (RFBM = 0b11)
movq $3, %rax
xor %rdx, %rdx
xrstor  UC_MCONTEXT_SIZE(\buf)
.endm

.macro FXSAVE_RESTORE buf=%rdi
movq 287+UC_MCONTEXT_SIZE     (\buf), %xmm8
movq 287+UC_MCONTEXT_SIZE+0x08(\buf), %xmm9
movq 287+UC_MCONTEXT_SIZE+0x10(\buf), %xmm10
movq 287+UC_MCONTEXT_SIZE+0x18(\buf), %xmm11
movq 287+UC_MCONTEXT_SIZE+0x20(\buf), %xmm12
movq 287+UC_MCONTEXT_SIZE+0x28(\buf), %xmm13
movq 287+UC_MCONTEXT_SIZE+0x30(\buf), %xmm14
movq 287+UC_MCONTEXT_SIZE+0x38(\buf), %xmm15
fxrstor  UC_MCONTEXT_SIZE(\buf)
.endm
