/* Freestanding <stdio.h> for the wasm3 sandbox. Only the formatted-output
   subset wasm3 needs (snprintf/vsnprintf for names and error messages);
   implementations live in the shared kernel libc. */
#ifndef __WASM3_STDIO_H
#define __WASM3_STDIO_H

#include <stdarg.h>
#include <stddef.h>

#define NULL ((void *)0)
#define FILE void
#define stdout ((void *)0)
#define stderr ((void *)0)

int vsnprintf(char * s, size_t n, const char * fmt, va_list ap);
int snprintf(char * s, size_t n, const char * fmt, ...);

#endif
