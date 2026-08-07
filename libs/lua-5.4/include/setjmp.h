#ifndef FREESTANDING_SETJMP_H
#define FREESTANDING_SETJMP_H

typedef struct {
    unsigned long regs[8];
} jmp_buf[1];

int setjmp(jmp_buf env);
void longjmp(jmp_buf env, int val);

#define _setjmp setjmp
#define _longjmp longjmp

#endif
