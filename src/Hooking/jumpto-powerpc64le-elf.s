.text
.align 4,0x90
.globl hooking_jl_jumpto
hooking_jl_jumpto:

nop # replace by trap for debugging purposes

# r3 is our buffer, so we'll restore that last, until then,
# we pretty much go in reverse order from what we did while

# Restore fpscr
ld %r9, UC_MCONTEXT_GREGS_FPSCR(%r3)
mtfsf 1,%r9,1,0

# Restore CR
ld %r8, UC_MCONTEXT_GREGS_CR(%r3)
mtcr %r8

# Restore XER
ld %r7, UC_MCONTEXT_GREGS_XER(%r3)
mtxer %r7

# Restore CTR
ld %r6, UC_MCONTEXT_GREGS_CTR(%r3)
mtctr %r6

# Restore LR (In this file we override this later, but
# we also use this code as the template for deopt, where
# we jump through ctr)
ld %r0, UC_MCONTEXT_GREGS_LR(%r3)
mtlr %r0

# IP is restored later, LR is clobbered, SP will be
# restored as part of the GPRs

# Save general register state
# r0 is used as scratch below, and will be
# restored after.
ld %r1, UC_MCONTEXT_GREGS_R1(%r3)
ld %r2, UC_MCONTEXT_GREGS_R2(%r3)
# r3 is restored later when we're done
ld %r4, UC_MCONTEXT_GREGS_R4(%r3)
ld %r5, UC_MCONTEXT_GREGS_R5(%r3)
ld %r6, UC_MCONTEXT_GREGS_R6(%r3)
ld %r7, UC_MCONTEXT_GREGS_R7(%r3)
ld %r8, UC_MCONTEXT_GREGS_R8(%r3)
ld %r9, UC_MCONTEXT_GREGS_R9(%r3)
ld %r10, UC_MCONTEXT_GREGS_R10(%r3)
ld %r11, UC_MCONTEXT_GREGS_R11(%r3)
ld %r12, UC_MCONTEXT_GREGS_R12(%r3)
ld %r13, UC_MCONTEXT_GREGS_R13(%r3)
ld %r14, UC_MCONTEXT_GREGS_R14(%r3)
ld %r15, UC_MCONTEXT_GREGS_R15(%r3)
ld %r16, UC_MCONTEXT_GREGS_R16(%r3)
ld %r17, UC_MCONTEXT_GREGS_R17(%r3)
ld %r18, UC_MCONTEXT_GREGS_R18(%r3)
ld %r19, UC_MCONTEXT_GREGS_R19(%r3)
ld %r20, UC_MCONTEXT_GREGS_R20(%r3)
ld %r21, UC_MCONTEXT_GREGS_R21(%r3)
ld %r22, UC_MCONTEXT_GREGS_R22(%r3)
ld %r23, UC_MCONTEXT_GREGS_R23(%r3)
ld %r24, UC_MCONTEXT_GREGS_R24(%r3)
ld %r25, UC_MCONTEXT_GREGS_R25(%r3)
ld %r26, UC_MCONTEXT_GREGS_R26(%r3)
ld %r27, UC_MCONTEXT_GREGS_R27(%r3)
ld %r28, UC_MCONTEXT_GREGS_R28(%r3)
ld %r29, UC_MCONTEXT_GREGS_R29(%r3)
ld %r30, UC_MCONTEXT_GREGS_R30(%r3)
ld %r31, UC_MCONTEXT_GREGS_R31(%r3)

# Save floating point register state
lfd %f0, UC_MCONTEXT_GREGS_F0(%r3)
lfd %f1, UC_MCONTEXT_GREGS_F1(%r3)
lfd %f2, UC_MCONTEXT_GREGS_F2(%r3)
lfd %f3, UC_MCONTEXT_GREGS_F3(%r3)
lfd %f4, UC_MCONTEXT_GREGS_F4(%r3)
lfd %f5, UC_MCONTEXT_GREGS_F5(%r3)
lfd %f6, UC_MCONTEXT_GREGS_F6(%r3)
lfd %f7, UC_MCONTEXT_GREGS_F7(%r3)
lfd %f8, UC_MCONTEXT_GREGS_F8(%r3)
lfd %f9, UC_MCONTEXT_GREGS_F9(%r3)
lfd %f10, UC_MCONTEXT_GREGS_F10(%r3)
lfd %f11, UC_MCONTEXT_GREGS_F11(%r3)
lfd %f12, UC_MCONTEXT_GREGS_F12(%r3)
lfd %f13, UC_MCONTEXT_GREGS_F13(%r3)
lfd %f14, UC_MCONTEXT_GREGS_F14(%r3)
lfd %f15, UC_MCONTEXT_GREGS_F15(%r3)
lfd %f16, UC_MCONTEXT_GREGS_F16(%r3)
lfd %f17, UC_MCONTEXT_GREGS_F17(%r3)
lfd %f18, UC_MCONTEXT_GREGS_F18(%r3)
lfd %f19, UC_MCONTEXT_GREGS_F19(%r3)
lfd %f20, UC_MCONTEXT_GREGS_F20(%r3)
lfd %f21, UC_MCONTEXT_GREGS_F21(%r3)
lfd %f22, UC_MCONTEXT_GREGS_F22(%r3)
lfd %f23, UC_MCONTEXT_GREGS_F23(%r3)
lfd %f24, UC_MCONTEXT_GREGS_F24(%r3)
lfd %f25, UC_MCONTEXT_GREGS_F25(%r3)
lfd %f26, UC_MCONTEXT_GREGS_F26(%r3)
lfd %f27, UC_MCONTEXT_GREGS_F27(%r3)
lfd %f28, UC_MCONTEXT_GREGS_F28(%r3)
lfd %f29, UC_MCONTEXT_GREGS_F29(%r3)
lfd %f30, UC_MCONTEXT_GREGS_F30(%r3)
lfd %f31, UC_MCONTEXT_GREGS_F31(%r3)

# Set lr to the ip we came from
ld %r0, UC_MCONTEXT_GREGS_PC(%r3)
mtlr %r0

# Restore r0 scratch register
ld %r0, UC_MCONTEXT_GREGS_R0(%r3)

# Finally restore r3
ld %r3, UC_MCONTEXT_GREGS_R3(%r3)

blr
