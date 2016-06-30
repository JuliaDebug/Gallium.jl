# cpp getcontext-x86_64-elf.s | ~/julia-debugger/usr/bin/llvm-mc -filetype=obj - -o elfhook.o
# Saves registers in a stack buffer in the order that the
# platform convention requires, then calls a callback passing
# the address of the stack buffer as that function's first
# argument.

.text
.align 4,0x90
.globl hooking_jl_savecontext
hooking_jl_savecontext:
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

# Save FP and SSE state (RFBM = 0b11)
movq $3, %rax
xor %rdx, %rdx

# Zero out the XSAVE Header
xor %rbx, %rbx
movq    %rbx,        512+UC_MCONTEXT_SIZE(%rsp)
movq    %rbx,   0x08+512+UC_MCONTEXT_SIZE(%rsp)
movq    %rbx,   0x10+512+UC_MCONTEXT_SIZE(%rsp)
movq    %rbx,   0x18+512+UC_MCONTEXT_SIZE(%rsp)
movq    %rbx,   0x20+512+UC_MCONTEXT_SIZE(%rsp)
movq    %rbx,   0x28+512+UC_MCONTEXT_SIZE(%rsp)
movq    %rbx,   0x30+512+UC_MCONTEXT_SIZE(%rsp)
movq    %rbx,   0x38+512+UC_MCONTEXT_SIZE(%rsp)

# The actual xsave
xsave   UC_MCONTEXT_SIZE(%rsp)
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
nop
movq    %rax, UC_MCONTEXT_GREGS_RAX(%rdi)
movq    %rbx, UC_MCONTEXT_GREGS_RBX(%rdi)
movq    %rcx, UC_MCONTEXT_GREGS_RCX(%rdi)
movq    %rdx, UC_MCONTEXT_GREGS_RDX(%rdi)
movq    %rdi, UC_MCONTEXT_GREGS_RDI(%rdi)
movq    %rsi, UC_MCONTEXT_GREGS_RSI(%rdi)
movq    %rbp, UC_MCONTEXT_GREGS_RBP(%rdi)
movq    %rsp, UC_MCONTEXT_GREGS_RSP(%rdi)
addq    $8,   UC_MCONTEXT_GREGS_RSP(%rdi)
movq    %r8,  UC_MCONTEXT_GREGS_R8(%rdi)
movq    %r9,  UC_MCONTEXT_GREGS_R9(%rdi)
movq    %r10, UC_MCONTEXT_GREGS_R10(%rdi)
movq    %r11, UC_MCONTEXT_GREGS_R11(%rdi)
movq    %r12, UC_MCONTEXT_GREGS_R12(%rdi)
movq    %r13, UC_MCONTEXT_GREGS_R13(%rdi)
movq    %r14, UC_MCONTEXT_GREGS_R14(%rdi)
movq    %r15, UC_MCONTEXT_GREGS_R15(%rdi)
movq    (%rsp),%rsi
movq    %rsi, UC_MCONTEXT_GREGS_RIP(%rdi) # store return address as rip

# Save FP and SSE state (RFBM = 0b11)
movq $3, %rax
xor %rdx, %rdx

# Zero out the XSAVE Header
xor %rsi, %rsi
movq    %rsi,        512+UC_MCONTEXT_SIZE(%rdi)
movq    %rsi,   0x08+512+UC_MCONTEXT_SIZE(%rdi)
movq    %rsi,   0x10+512+UC_MCONTEXT_SIZE(%rdi)
movq    %rsi,   0x18+512+UC_MCONTEXT_SIZE(%rdi)
movq    %rsi,   0x20+512+UC_MCONTEXT_SIZE(%rdi)
movq    %rsi,   0x28+512+UC_MCONTEXT_SIZE(%rdi)
movq    %rsi,   0x30+512+UC_MCONTEXT_SIZE(%rdi)
movq    %rsi,   0x38+512+UC_MCONTEXT_SIZE(%rdi)

# The actual xsave
xsave   UC_MCONTEXT_SIZE(%rdi)

retq

.section	.note.GNU-stack,"",@progbits
