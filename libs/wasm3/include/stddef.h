/* Freestanding <stddef.h> for the wasm3 sandbox (no libc in the kernel). */
#ifndef __WASM3_STDDEF_H
#define __WASM3_STDDEF_H

typedef __SIZE_TYPE__ size_t;
typedef __PTRDIFF_TYPE__ ptrdiff_t;
#ifndef NULL
#define NULL ((void *)0)
#endif
#define offsetof(type, member) __builtin_offsetof(type, member)

#endif
