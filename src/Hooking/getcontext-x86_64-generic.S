.macro SAVE_GPREGS
nop
pushq   %rbp
movq    %rsp, %rbp
subq    $UC_MCONTEXT_TOTAL_SIZE,    %rsp
# Align stack to 56 byte boundary (to make sure xsave area ends up on 64 byte boundary)
andq    $-64, %rsp
subq    $8, %rsp
# Get rax from one above the stack pointer
# (caller's responsibility to save)
movq    16(%rbp),%rax

movq    %rax, UC_MCONTEXT_GREGS_RAX(%rsp)
movq    %rbx, UC_MCONTEXT_GREGS_RBX(%rsp)
movq    %rcx, UC_MCONTEXT_GREGS_RCX(%rsp)
movq    %rdx, UC_MCONTEXT_GREGS_RDX(%rsp)
movq    %rdi, UC_MCONTEXT_GREGS_RDI(%rsp)
movq    %rsi, UC_MCONTEXT_GREGS_RSI(%rsp)
movq    8(%rbp),%rsi
movq    %rsi, UC_MCONTEXT_GREGS_RIP(%rsp) # store return address as rip
movq    %rbp, UC_MCONTEXT_GREGS_RSP(%rsp)
addq    $24, UC_MCONTEXT_GREGS_RSP(%rsp)
movq    (%rbp), %rbp
movq    %rbp, UC_MCONTEXT_GREGS_RBP(%rsp)
movq    %r8,  UC_MCONTEXT_GREGS_R8(%rsp)
movq    %r9,  UC_MCONTEXT_GREGS_R9(%rsp)
movq    %r10, UC_MCONTEXT_GREGS_R10(%rsp)
movq    %r11, UC_MCONTEXT_GREGS_R11(%rsp)
movq    %r12, UC_MCONTEXT_GREGS_R12(%rsp)
movq    %r13, UC_MCONTEXT_GREGS_R13(%rsp)
movq    %r14, UC_MCONTEXT_GREGS_R14(%rsp)
movq    %r15, UC_MCONTEXT_GREGS_R15(%rsp)
.endm


.macro DO_XSAVE buf=%rsp
# Save FP and SSE state (RFBM = 0b11)
movq $3, %rax
xor %rdx, %rdx

# Zero out the XSAVE Header
xor %rbx, %rbx
movq    %rbx,        512+UC_MCONTEXT_SIZE(\buf)
movq    %rbx,   0x08+512+UC_MCONTEXT_SIZE(\buf)
movq    %rbx,   0x10+512+UC_MCONTEXT_SIZE(\buf)
movq    %rbx,   0x18+512+UC_MCONTEXT_SIZE(\buf)
movq    %rbx,   0x20+512+UC_MCONTEXT_SIZE(\buf)
movq    %rbx,   0x28+512+UC_MCONTEXT_SIZE(\buf)
movq    %rbx,   0x30+512+UC_MCONTEXT_SIZE(\buf)
movq    %rbx,   0x38+512+UC_MCONTEXT_SIZE(\buf)

# The actual xsave
xsave   UC_MCONTEXT_SIZE(\buf)
.endm

.macro DO_FXSAVE buf=%rsp
# Use fxsave for floating point state, and xmm0-7.
# Then, manually fill in xmm8-xmm15
fxsave UC_MCONTEXT_SIZE(\buf)
movq %xmm8 , 287+UC_MCONTEXT_SIZE     (\buf)
movq %xmm9 , 287+UC_MCONTEXT_SIZE+0x08(\buf)
movq %xmm10, 287+UC_MCONTEXT_SIZE+0x10(\buf)
movq %xmm11, 287+UC_MCONTEXT_SIZE+0x18(\buf)
movq %xmm12, 287+UC_MCONTEXT_SIZE+0x20(\buf)
movq %xmm13, 287+UC_MCONTEXT_SIZE+0x28(\buf)
movq %xmm14, 287+UC_MCONTEXT_SIZE+0x30(\buf)
movq %xmm15, 287+UC_MCONTEXT_SIZE+0x38(\buf)
.endm

.macro SAVE_GPREGS_SIMPLE buf=%rdi
nop
movq    %rax, UC_MCONTEXT_GREGS_RAX(\buf)
movq    %rbx, UC_MCONTEXT_GREGS_RBX(\buf)
movq    %rcx, UC_MCONTEXT_GREGS_RCX(\buf)
movq    %rdx, UC_MCONTEXT_GREGS_RDX(\buf)
movq    %rdi, UC_MCONTEXT_GREGS_RDI(\buf)
movq    %rsi, UC_MCONTEXT_GREGS_RSI(\buf)
movq    %rbp, UC_MCONTEXT_GREGS_RBP(\buf)
movq    %rsp, UC_MCONTEXT_GREGS_RSP(\buf)
addq    $8,   UC_MCONTEXT_GREGS_RSP(\buf)
movq    %r8,  UC_MCONTEXT_GREGS_R8(\buf)
movq    %r9,  UC_MCONTEXT_GREGS_R9(\buf)
movq    %r10, UC_MCONTEXT_GREGS_R10(\buf)
movq    %r11, UC_MCONTEXT_GREGS_R11(\buf)
movq    %r12, UC_MCONTEXT_GREGS_R12(\buf)
movq    %r13, UC_MCONTEXT_GREGS_R13(\buf)
movq    %r14, UC_MCONTEXT_GREGS_R14(\buf)
movq    %r15, UC_MCONTEXT_GREGS_R15(\buf)
movq    (%rsp),%rsi
movq    %rsi, UC_MCONTEXT_GREGS_RIP(%rdi) # store return address as rip
.endm
