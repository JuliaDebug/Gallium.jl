.text
.globl _start
.type _start, @function
_start:
  .cfi_startproc
  .cfi_undefined %rip
  movq func1@GOTPCREL(%rip), %rax
  callq func1@plt
  callq func2@plt
  movq func3@GOTPCREL(%rip), %rax
  hlt
  .cfi_endproc
