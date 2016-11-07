.text
.globl _start
.type _start, @function
_start:
  .cfi_startproc
  .cfi_undefined %rip
  movq	%rsp, %rdi
  callq callee
  .cfi_endproc
.global callee
.type callee, @function
callee:
  .cfi_startproc
  pushq	%rbp
  movq	%rsp, %rbp
  hlt
  .cfi_endproc
