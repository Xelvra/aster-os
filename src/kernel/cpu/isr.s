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
  /* The stubs push the vector with `push imm8`, which sign-extends vectors
     >= 0x80 (e.g. spurious 0xFF arrives as 0xFFFFFFFFFFFFFFFF). Fix it in
     place so InterruptFrame.vector is always the real 8-bit vector. */
  andq $0xFF, (%rsp)
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
  /* Save the full SSE state below the InterruptFrame. Interrupts can fire
     between instructions that copy structs through XMM registers (movdqu),
     so the ISR must not clobber them. Keep the frame pointer (rdi) before
     the subq so the XMM area does not shift the InterruptFrame layout. */
  movq %rsp, %rdi
  subq $256, %rsp
  movdqu %xmm0, 0x00(%rsp)
  movdqu %xmm1, 0x10(%rsp)
  movdqu %xmm2, 0x20(%rsp)
  movdqu %xmm3, 0x30(%rsp)
  movdqu %xmm4, 0x40(%rsp)
  movdqu %xmm5, 0x50(%rsp)
  movdqu %xmm6, 0x60(%rsp)
  movdqu %xmm7, 0x70(%rsp)
  movdqu %xmm8, 0x80(%rsp)
  movdqu %xmm9, 0x90(%rsp)
  movdqu %xmm10, 0xa0(%rsp)
  movdqu %xmm11, 0xb0(%rsp)
  movdqu %xmm12, 0xc0(%rsp)
  movdqu %xmm13, 0xd0(%rsp)
  movdqu %xmm14, 0xe0(%rsp)
  movdqu %xmm15, 0xf0(%rsp)
  callq handle_isr
  /* Preemptive task switch — timer vector only (see sched/task.zig). The
     vector field of InterruptFrame sits at 0x178(%rsp): frame start is
     0x100 below %rsp, the vector field is at offset 120 (0x78). Other
     vectors skip the switch entirely, preserving the C35 invariant (full
     XMM/GPR save+restore) for all of them. */
  cmpq $0x20, 0x178(%rsp)
  jne 1f
  callq sched_switch
1:
  /* Restore sequence. Every task's saved stack pointer points at a copy of
     this label's address — preempted tasks: pushed by `callq sched_switch`;
     new tasks: assembled by buildFakeFrame — so the `ret` in sched_switch
     lands here no matter which task is resumed. */
  .globl sched_restore
sched_restore:
  movdqu 0xf0(%rsp), %xmm15
  movdqu 0xe0(%rsp), %xmm14
  movdqu 0xd0(%rsp), %xmm13
  movdqu 0xc0(%rsp), %xmm12
  movdqu 0xb0(%rsp), %xmm11
  movdqu 0xa0(%rsp), %xmm10
  movdqu 0x90(%rsp), %xmm9
  movdqu 0x80(%rsp), %xmm8
  movdqu 0x70(%rsp), %xmm7
  movdqu 0x60(%rsp), %xmm6
  movdqu 0x50(%rsp), %xmm5
  movdqu 0x40(%rsp), %xmm4
  movdqu 0x30(%rsp), %xmm3
  movdqu 0x20(%rsp), %xmm2
  movdqu 0x10(%rsp), %xmm1
  movdqu 0x00(%rsp), %xmm0
  addq $256, %rsp
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

  /* Task switch bridge (brief Task 7.2). On entry %rsp points at the return
     address of the `callq sched_switch` (the sched_restore label) — that is
     the current task's saved_sp. Ask the Zig scheduler for the next task and
     switch: interrupts are already masked here (interrupt gate, IF=0) and the
     `cli` keeps them masked as the last instruction before the switch; the
     final `ret` reads the restore-sequence address off the NEW task's stack.
     Save `current_rsp` BEFORE aligning: %rsp itself is the argument and must
     still point at the return-address slot. sched_pick_next is normal Zig
     code and requires the SysV stack alignment (16 bytes). */
  .globl sched_switch
sched_switch:
  movq %rsp, %rdi
  andq $-16, %rsp
  callq sched_pick_next
  cli
  movq %rax, %rsp
  ret
