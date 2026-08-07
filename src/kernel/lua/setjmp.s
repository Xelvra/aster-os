# Freestanding setjmp/longjmp for x86_64 (SysV ABI).
# jmp_buf layout: [0]=rbx, [1]=rbp, [2]=r12, [3]=r13, [4]=r14,
#                 [5]=r15, [6]=rsp, [7]=rip (return address)
# setjmp(jmp_buf env) -> int  (0 on first call, nonzero after longjmp)

.global setjmp
.type setjmp, @function
setjmp:
    movq %rbx, 0(%rdi)
    movq %rbp, 8(%rdi)
    movq %r12, 16(%rdi)
    movq %r13, 24(%rdi)
    movq %r14, 32(%rdi)
    movq %r15, 40(%rdi)
    movq %rsp, 48(%rdi)
    movq (%rsp), %rax
    movq %rax, 56(%rdi)
    xorl %eax, %eax
    ret

.global longjmp
.type longjmp, @function
# longjmp(jmp_buf env, int val)
longjmp:
    movq 0(%rdi), %rbx
    movq 8(%rdi), %rbp
    movq 16(%rdi), %r12
    movq 24(%rdi), %r13
    movq 32(%rdi), %r14
    movq 40(%rdi), %r15
    movq 48(%rdi), %rsp
    movq 56(%rdi), %rax
    movq %rax, (%rsp)
    movq %rsi, %rax
    testq %rax, %rax
    jnz 1f
    movl $1, %eax
1:
    ret

.section .note.GNU-stack,"",@progbits
