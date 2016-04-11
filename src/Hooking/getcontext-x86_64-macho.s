# Saves registers in a stack buffer in the order that the
# platform convention requires, then calls a callback passing
# the address of the stack buffer as that function's first
# argument.

.text
.align 4,0x90
.globl _hooking_jl_savecontext
_hooking_jl_savecontext:
int $3
subq    $136,    %rsp
# Get rax from one above the stack pointer
# (caller's responsibility to save)
movq    144(%rsp),%rax
movq    %rax,   (%rsp)
movq    %rbx,  8(%rsp)
movq    %rcx, 16(%rsp)
movq    %rdx, 24(%rsp)
movq    %rdi, 32(%rsp)
movq    %rsi, 40(%rsp)
movq    %rbp, 48(%rsp)
movq    %rsp, 56(%rsp)
addq    $152, 56(%rsp)
movq    %r8,  64(%rsp)
movq    %r9,  72(%rsp)
movq    %r10, 80(%rsp)
movq    %r11, 88(%rsp)
movq    %r12, 96(%rsp)
movq    %r13,104(%rsp)
movq    %r14,112(%rsp)
movq    %r15,120(%rsp)
movq    136(%rsp),%rsi
movq    %rsi,128(%rsp) # store return address as rip
movq    %rsp,    %rdi
pushq   %rsi           # Makes the debugger's life easier
movq _hooking_jl_callback@GOTPCREL(%rip), %rax
jmpq *(%rax)

.text
.align 4,0x90
.globl _hooking_jl_simple_savecontext
_hooking_jl_simple_savecontext:
nop
movq    %rax, UC_MCONTEXT_GREGS_RAX(%rdi)
movq    %rbx, UC_MCONTEXT_GREGS_RBX(%rdi)
movq    %rcx, UC_MCONTEXT_GREGS_RCX(%rdi)
movq    %rdx, UC_MCONTEXT_GREGS_RDX(%rdi)
movq    %rdi, UC_MCONTEXT_GREGS_RDI(%rdi)
movq    %rsi, UC_MCONTEXT_GREGS_RSI(%rdi)
movq    %rbp, UC_MCONTEXT_GREGS_RBP(%rdi)
movq    %rsp, UC_MCONTEXT_GREGS_RSP(%rdi)
addq    $(UC_MCONTEXT_SIZE+8), UC_MCONTEXT_GREGS_RSP(%rdi)
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
retq

.subsections_via_symbols
