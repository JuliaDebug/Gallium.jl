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
addi    %r1, %r1, -UC_MCONTEXT_TOTAL_SIZE

# Save general register state
std %r0, UC_MCONTEXT_GREGS_R0(%r1)
# Skip R1, we'll set it below
std %r2, UC_MCONTEXT_GREGS_R2(%r1)
std %r3, UC_MCONTEXT_GREGS_R3(%r1)
std %r4, UC_MCONTEXT_GREGS_R4(%r1)
std %r5, UC_MCONTEXT_GREGS_R5(%r1)
std %r6, UC_MCONTEXT_GREGS_R6(%r1)
std %r7, UC_MCONTEXT_GREGS_R7(%r1)
std %r8, UC_MCONTEXT_GREGS_R8(%r1)
std %r9, UC_MCONTEXT_GREGS_R9(%r1)
std %r10, UC_MCONTEXT_GREGS_R10(%r1)
std %r11, UC_MCONTEXT_GREGS_R11(%r1)
std %r12, UC_MCONTEXT_GREGS_R12(%r1)
std %r13, UC_MCONTEXT_GREGS_R13(%r1)
std %r14, UC_MCONTEXT_GREGS_R14(%r1)
std %r15, UC_MCONTEXT_GREGS_R15(%r1)
std %r16, UC_MCONTEXT_GREGS_R16(%r1)
std %r17, UC_MCONTEXT_GREGS_R17(%r1)
std %r18, UC_MCONTEXT_GREGS_R18(%r1)
std %r19, UC_MCONTEXT_GREGS_R19(%r1)
std %r20, UC_MCONTEXT_GREGS_R20(%r1)
std %r21, UC_MCONTEXT_GREGS_R21(%r1)
std %r22, UC_MCONTEXT_GREGS_R22(%r1)
std %r23, UC_MCONTEXT_GREGS_R23(%r1)
std %r24, UC_MCONTEXT_GREGS_R24(%r1)
std %r25, UC_MCONTEXT_GREGS_R25(%r1)
std %r26, UC_MCONTEXT_GREGS_R26(%r1)
std %r27, UC_MCONTEXT_GREGS_R27(%r1)
std %r28, UC_MCONTEXT_GREGS_R28(%r1)
std %r29, UC_MCONTEXT_GREGS_R29(%r1)
std %r30, UC_MCONTEXT_GREGS_R30(%r1)
std %r31, UC_MCONTEXT_GREGS_R31(%r1)

# Save floating point register state
std %f0, UC_MCONTEXT_GREGS_F0(%r1)
std %f1, UC_MCONTEXT_GREGS_F1(%r1)
std %f2, UC_MCONTEXT_GREGS_F2(%r1)
std %f3, UC_MCONTEXT_GREGS_F3(%r1)
std %f4, UC_MCONTEXT_GREGS_F4(%r1)
std %f5, UC_MCONTEXT_GREGS_F5(%r1)
std %f6, UC_MCONTEXT_GREGS_F6(%r1)
std %f7, UC_MCONTEXT_GREGS_F7(%r1)
std %f8, UC_MCONTEXT_GREGS_F8(%r1)
std %f9, UC_MCONTEXT_GREGS_F9(%r1)
std %f10, UC_MCONTEXT_GREGS_F10(%r1)
std %f11, UC_MCONTEXT_GREGS_F11(%r1)
std %f12, UC_MCONTEXT_GREGS_F12(%r1)
std %f13, UC_MCONTEXT_GREGS_F13(%r1)
std %f14, UC_MCONTEXT_GREGS_F14(%r1)
std %f15, UC_MCONTEXT_GREGS_F15(%r1)
std %f16, UC_MCONTEXT_GREGS_F16(%r1)
std %f17, UC_MCONTEXT_GREGS_F17(%r1)
std %f18, UC_MCONTEXT_GREGS_F18(%r1)
std %f19, UC_MCONTEXT_GREGS_F19(%r1)
std %f20, UC_MCONTEXT_GREGS_F20(%r1)
std %f21, UC_MCONTEXT_GREGS_F21(%r1)
std %f22, UC_MCONTEXT_GREGS_F22(%r1)
std %f23, UC_MCONTEXT_GREGS_F23(%r1)
std %f24, UC_MCONTEXT_GREGS_F24(%r1)
std %f25, UC_MCONTEXT_GREGS_F25(%r1)
std %f26, UC_MCONTEXT_GREGS_F26(%r1)
std %f27, UC_MCONTEXT_GREGS_F27(%r1)
std %f28, UC_MCONTEXT_GREGS_F28(%r1)
std %f29, UC_MCONTEXT_GREGS_F29(%r1)
std %f30, UC_MCONTEXT_GREGS_F30(%r1)
std %f31, UC_MCONTEXT_GREGS_F31(%r1)

# Save stack pointer
addi %r3, %r1, UC_MCONTEXT_TOTAL_SIZE
std %r3, UC_MCONTEXT_GREGS_R1(%r1)

# Save link register (stored at 4(%r1) before branching here)
ld %r4, 4+UC_MCONTEXT_TOTAL_SIZE(%r1)
std %r4, UC_MCONTEXT_GREGS_LINK(%r1)

# Store IP
mflr %r5
# Adjust IP?
std %r5, UC_MCONTEXT_GREGS_NIP(%r1)

# Store CTR
mfctr %r6
std %r6, UC_MCONTEXT_CTR(%r1)

# Store xer
mfxer %r7
std %r7, UC_MCONTEXT_XER(%r1)

# Store CR
mfcr %r8
std %r8, UC_MCONTEXT_CCR(%r1)

# Store fpscr
mffs %r9
std %r9, UC_MCONTEXT_FPSCR(%r1)

# Branch to callback
mr %r3, %r1

ld %r6, hooking_jl_callback@got(%r2)
ld %r6, 0(%r6)
ld %r0, 0(%r6)
mtlr %r0
# Set up new toc base
ld %r2, 8(%r6)
blrl
nop

.section	.note.GNU-stack,"",@progbits
