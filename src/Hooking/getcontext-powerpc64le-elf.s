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
stfd %f0, UC_MCONTEXT_GREGS_F0(%r1)
stfd %f1, UC_MCONTEXT_GREGS_F1(%r1)
stfd %f2, UC_MCONTEXT_GREGS_F2(%r1)
stfd %f3, UC_MCONTEXT_GREGS_F3(%r1)
stfd %f4, UC_MCONTEXT_GREGS_F4(%r1)
stfd %f5, UC_MCONTEXT_GREGS_F5(%r1)
stfd %f6, UC_MCONTEXT_GREGS_F6(%r1)
stfd %f7, UC_MCONTEXT_GREGS_F7(%r1)
stfd %f8, UC_MCONTEXT_GREGS_F8(%r1)
stfd %f9, UC_MCONTEXT_GREGS_F9(%r1)
stfd %f10, UC_MCONTEXT_GREGS_F10(%r1)
stfd %f11, UC_MCONTEXT_GREGS_F11(%r1)
stfd %f12, UC_MCONTEXT_GREGS_F12(%r1)
stfd %f13, UC_MCONTEXT_GREGS_F13(%r1)
stfd %f14, UC_MCONTEXT_GREGS_F14(%r1)
stfd %f15, UC_MCONTEXT_GREGS_F15(%r1)
stfd %f16, UC_MCONTEXT_GREGS_F16(%r1)
stfd %f17, UC_MCONTEXT_GREGS_F17(%r1)
stfd %f18, UC_MCONTEXT_GREGS_F18(%r1)
stfd %f19, UC_MCONTEXT_GREGS_F19(%r1)
stfd %f20, UC_MCONTEXT_GREGS_F20(%r1)
stfd %f21, UC_MCONTEXT_GREGS_F21(%r1)
stfd %f22, UC_MCONTEXT_GREGS_F22(%r1)
stfd %f23, UC_MCONTEXT_GREGS_F23(%r1)
stfd %f24, UC_MCONTEXT_GREGS_F24(%r1)
stfd %f25, UC_MCONTEXT_GREGS_F25(%r1)
stfd %f26, UC_MCONTEXT_GREGS_F26(%r1)
stfd %f27, UC_MCONTEXT_GREGS_F27(%r1)
stfd %f28, UC_MCONTEXT_GREGS_F28(%r1)
stfd %f29, UC_MCONTEXT_GREGS_F29(%r1)
stfd %f30, UC_MCONTEXT_GREGS_F30(%r1)
stfd %f31, UC_MCONTEXT_GREGS_F31(%r1)

# Save stack pointer
addi %r3, %r1, UC_MCONTEXT_TOTAL_SIZE
std %r3, UC_MCONTEXT_GREGS_R1(%r1)

# Save link register (stored at 4(%r1) before branching here)
ld %r4, 4+UC_MCONTEXT_TOTAL_SIZE(%r1)
std %r4, UC_MCONTEXT_GREGS_LR(%r1)

# Store IP
mflr %r5
# Adjust IP?
std %r5, UC_MCONTEXT_GREGS_PC(%r1)

# Store CTR
mfctr %r6
std %r6, UC_MCONTEXT_GREGS_CTR(%r1)

# Store xer
mfxer %r7
std %r7, UC_MCONTEXT_GREGS_XER(%r1)

# Store CR
mfcr %r8
std %r8, UC_MCONTEXT_GREGS_CR(%r1)

# Store fpscr
mffs %r9
std %r9, UC_MCONTEXT_GREGS_FPSCR(%r1)

# Branch to callback
mr %r3, %r1

# Make sure that the callee doesn't smash our stack buffer
addi %r1, %r1, -160

# We didn't properly set r2 when we jumped here
# to save some instructions. So fake PC-relative
# addressing to get it back.
bl next_inst
next_inst:
mflr %r2
addi %r2, %r2, (.TOC.-next_inst)@l
addis %r2, %r2, (.TOC.-next_inst)@h
ld %r12, hooking_jl_callback@got(%r2)
ld %r12, 0(%r12)
mtlr %r12
blrl
nop

.section	.note.GNU-stack,"",@progbits
