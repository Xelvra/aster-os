/* AP trampoline (SMP bring-up). The BSP copies this block to the low-memory
   page tramp_base (0x8000) and starts each Application Processor with
   INIT -> SIPI -> SIPI. The code is position-independent: it only ever touches
   the block itself, addressed relative to the running instruction (getip
   pattern in 16/32-bit, RIP-relative in 64-bit), so it works from its
   temporary low-memory home even though the kernel lives in the higher half.

   Layout of the 4 KiB block:
     0x0000  16-bit real-mode entry
     ...     32-bit protected-mode entry
     ...     64-bit long-mode entry
     ...     GDT + GDT pointer
     ...     per-AP data (written by the BSP before each SIPI) */

.set tramp_base, 0x8000

.section .trampoline, "ax"

.globl smp_trampoline_start
smp_trampoline_start:

/* ---- 16-bit real mode -------------------------------------------------- */
.code16
  cli
  movl $0x11, (tramp_base + smp_marks - smp_trampoline_start)
  xorw %ax, %ax
  movw %ax, %ds
  movw %ax, %es
  /* Load the trampoline GDT: ds = 0, so the operand is the physical address
     of the GDT pointer inside the block (tramp_base + block offset; it fits
     a 16-bit address because the whole block lives below 1 MiB). */
  lgdtw (tramp_base + smp_gdt_ptr - smp_trampoline_start)
  movl $0x12, (tramp_base + smp_marks - smp_trampoline_start)
  movl %cr0, %eax
  orl $1, %eax
  movl %eax, %cr0
  /* Far jump into the 32-bit segment. The target is the physical address of
     the 32-bit entry (tramp_base + block offset); a 32-bit operand-size far
     jump is required because that address exceeds the 16-bit offset range. */
  ljmpl $0x08, $(tramp_base + smp_pm32 - smp_trampoline_start)

/* ---- 32-bit protected mode --------------------------------------------- */
.code32
smp_pm32:
  movl $0x13, (tramp_base + smp_marks - smp_trampoline_start)
  movw $0x10, %ax
  movw %ax, %ds
  movw %ax, %es
  movw %ax, %ss
  /* Read the page-table root (BSP CR3) via the getip pattern: ebx = address
     of the label below, the data offset is a block-relative constant. */
  call 1f
1:
  popl %ebx
  movl (smp_cr3 - 1b)(%ebx), %eax
  movl %eax, %cr3
  movl $0x14, (tramp_base + smp_marks - smp_trampoline_start)
  /* Long mode needs EFER.LME, and the BSP page tables set the NX bit on
     every entry — without EFER.NXE that bit is reserved and the first page
     walk raises a #PF(RSVD). Enable both before paging. */
  movl $0xC0000080, %ecx
  rdmsr
  orl $0x900, %eax /* LME | NXE */
  wrmsr
  movl %cr4, %eax
  orl $0x20, %eax
  orl $0x640, %eax /* PAE | PGE | OSFXSR | OSXMMEXCPT (mirror the BSP) */
  movl %eax, %cr4
  movl %cr0, %eax
  orl $0x80000000, %eax
  movl %eax, %cr0
  movl $0x15, (tramp_base + smp_marks - smp_trampoline_start)
1:
  jmp 1b
/* ---- 64-bit long mode --------------------------------------------------- */
.code64
smp_lm64:
  movw $0x30, %ax
  movw %ax, %ds
  movw %ax, %es
  movw %ax, %ss
  movl $0x16, (tramp_base + smp_marks - smp_trampoline_start)
  /* Per-AP values prepared by the BSP; RIP-relative so the low-memory copy
     still resolves them (the block offsets are identical at any base). */
  movq smp_cpu_id(%rip), %rdi
  movq smp_stack_top(%rip), %rsp
  xorl %ebp, %ebp
  movq smp_high64(%rip), %rax
  jmpq *%rax

/* ---- GDT ---------------------------------------------------------------- */
  .p2align 3
smp_gdt:
  .quad 0x0000000000000000 /* 0x00 null */
  .quad 0x00CF9A000000FFFF /* 0x08 32-bit code, base 0, limit 4 GiB */
  .quad 0x00CF92000000FFFF /* 0x10 32-bit data */
  .quad 0x00AF9A000000FFFF /* 0x18 64-bit code */
  .quad 0x00AF92000000FFFF /* 0x20 64-bit data */
  .quad 0x00AF9A000000FFFF /* 0x28 64-bit code (kernel CS, like the BSP) */
  .quad 0x00AF92000000FFFF /* 0x30 64-bit data (kernel SS/DS) */
  .quad 0x0000000000000000 /* 0x38 padding */
smp_gdt_ptr:
  .word smp_gdt_end - smp_gdt - 1
  .long tramp_base + (smp_gdt - smp_trampoline_start)
smp_gdt_end:

/* ---- per-AP data (written by the BSP before each SIPI) ------------------ */
  .p2align 3
.globl smp_cr3
smp_cr3:       .quad 0
.globl smp_cpu_id
smp_cpu_id:    .quad 0
.globl smp_stack_top
smp_stack_top: .quad 0
.globl smp_high64
smp_high64:    .quad 0
.globl smp_marks
smp_marks:     .quad 0

.globl smp_trampoline_end
smp_trampoline_end:

/* ---- higher-half AP entry ---------------------------------------------- */
.section .text, "ax"
.globl smp_ap_entry
smp_ap_entry:
  /* Entered with rsp = per-AP stack top (16-aligned, SysV ABI) and
     rdi = cpu_id. Call the Zig entry point; it never returns. */
  xorq %rbp, %rbp
  callq apEntry
