# cpp jumpto-x86_64-elf.s | ~/julia-debugger/usr/bin/llvm-mc -filetype=obj - -o elfjump.o

.macro RESTORE_GPREGS_AND_JMP
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

.text
.align 4,0x90
.globl hooking_jl_jumpto
hooking_jl_jumpto:
nop
# Restore FP and SSE state (RFBM = 0b11)
movq $3, %rax
xor %rdx, %rdx
xrstor  UC_MCONTEXT_SIZE(%rdi)

RESTORE_GPREGS_AND_JMP

.text
.align 4,0x90
.globl hooking_jl_jumpto_legacy
hooking_jl_jumpto_legacy:
nop
movq 287+UC_MCONTEXT_SIZE     (%rdi), %xmm8
movq 287+UC_MCONTEXT_SIZE+0x08(%rdi), %xmm9
movq 287+UC_MCONTEXT_SIZE+0x10(%rdi), %xmm10
movq 287+UC_MCONTEXT_SIZE+0x18(%rdi), %xmm11
movq 287+UC_MCONTEXT_SIZE+0x20(%rdi), %xmm12
movq 287+UC_MCONTEXT_SIZE+0x28(%rdi), %xmm13
movq 287+UC_MCONTEXT_SIZE+0x30(%rdi), %xmm14
movq 287+UC_MCONTEXT_SIZE+0x38(%rdi), %xmm15
fxrstor  UC_MCONTEXT_SIZE(%rdi)

RESTORE_GPREGS_AND_JMP

.section	.note.GNU-stack,"",@progbits
