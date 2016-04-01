# From libunwind:
#define UC_MCONTEXT_GREGS_R8    0x28
#define UC_MCONTEXT_GREGS_R9    0x30
#define UC_MCONTEXT_GREGS_R10   0x38
#define UC_MCONTEXT_GREGS_R11   0x40
#define UC_MCONTEXT_GREGS_R12   0x48
#define UC_MCONTEXT_GREGS_R13   0x50
#define UC_MCONTEXT_GREGS_R14   0x58
#define UC_MCONTEXT_GREGS_R15   0x60
#define UC_MCONTEXT_GREGS_RDI   0x68
#define UC_MCONTEXT_GREGS_RSI   0x70
#define UC_MCONTEXT_GREGS_RBP   0x78
#define UC_MCONTEXT_GREGS_RBX   0x80
#define UC_MCONTEXT_GREGS_RDX   0x88
#define UC_MCONTEXT_GREGS_RAX   0x90
#define UC_MCONTEXT_GREGS_RCX   0x98
#define UC_MCONTEXT_GREGS_RSP   0xa0
#define UC_MCONTEXT_GREGS_RIP   0xa8
# Needs to be aligned to 0x8 such that
# and extra push will 16byte align it.
#define UC_MCONTEXT_SIZE        0xb8
