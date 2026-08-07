.section .text.isr, "ax"
.globl isr_stubs
isr_stubs:
  /* 0-7: no error code */
  .byte 0x6a, 0x00; .byte 0x6a, 0x00; jmp isr_common
  .byte 0x6a, 0x00; .byte 0x6a, 0x01; jmp isr_common
  .byte 0x6a, 0x00; .byte 0x6a, 0x02; jmp isr_common
  .byte 0x6a, 0x00; .byte 0x6a, 0x03; jmp isr_common
  .byte 0x6a, 0x00; .byte 0x6a, 0x04; jmp isr_common
  .byte 0x6a, 0x00; .byte 0x6a, 0x05; jmp isr_common
  .byte 0x6a, 0x00; .byte 0x6a, 0x06; jmp isr_common
  .byte 0x6a, 0x00; .byte 0x6a, 0x07; jmp isr_common
  /* 8: double fault (error code) */
  .byte 0x6a, 0x08; jmp isr_common; .byte 0x90, 0x90
  /* 9: coprocessor (no error) */
  .byte 0x6a, 0x00; .byte 0x6a, 0x09; jmp isr_common
  /* 10-14: error code */
  .byte 0x6a, 0x0a; jmp isr_common; .byte 0x90, 0x90
  .byte 0x6a, 0x0b; jmp isr_common; .byte 0x90, 0x90
  .byte 0x6a, 0x0c; jmp isr_common; .byte 0x90, 0x90
  .byte 0x6a, 0x0d; jmp isr_common; .byte 0x90, 0x90
  .byte 0x6a, 0x0e; jmp isr_common; .byte 0x90, 0x90
  /* 15: reserved (no error) */
  .byte 0x6a, 0x00; .byte 0x6a, 0x0f; jmp isr_common
  /* 16: #MF (no error) */
  .byte 0x6a, 0x00; .byte 0x6a, 0x10; jmp isr_common
  /* 17: #AC (error code) */
  .byte 0x6a, 0x11; jmp isr_common; .byte 0x90, 0x90
  /* 18-20: no error */
  .byte 0x6a, 0x00; .byte 0x6a, 0x12; jmp isr_common
  .byte 0x6a, 0x00; .byte 0x6a, 0x13; jmp isr_common
  .byte 0x6a, 0x00; .byte 0x6a, 0x14; jmp isr_common
  /* 21: #CP (error code) */
  .byte 0x6a, 0x15; jmp isr_common; .byte 0x90, 0x90
  /* 22-31: no error */
  .set i, 0x16
  .rept 10
    .byte 0x6a, 0x00
    .byte 0x6a, i
    jmp isr_common
    .set i, i + 1
  .endr
  /* 32-255: IRQ, no error code */
  .set i, 0x20
  .rept 224
    .byte 0x6a, 0x00
    .byte 0x6a, i
    jmp isr_common
    .set i, i + 1
  .endr
.globl isr_common
isr_common:
  pushq %rax
  pushq %rbp
  pushq %rbx
  pushq %r15
  pushq %r14
  pushq %r13
  pushq %r12
  pushq %r11
  pushq %r10
  pushq %r9
  pushq %r8
  pushq %rdx
  pushq %rcx
  pushq %rsi
  pushq %rdi
  movq %rsp, %rdi
  callq handle_isr
  popq %rdi
  popq %rsi
  popq %rcx
  popq %rdx
  popq %r8
  popq %r9
  popq %r10
  popq %r11
  popq %r12
  popq %r13
  popq %r14
  popq %r15
  popq %rbx
  popq %rbp
  popq %rax
  addq $16, %rsp
  iretq
