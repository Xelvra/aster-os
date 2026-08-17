/* Freestanding <stdlib.h> for the wasm3 sandbox. malloc/free/realloc/abort
   are provided by the kernel (libs/wasm3/kernel_alloc.c). */
#ifndef __WASM3_STDLIB_H
#define __WASM3_STDLIB_H

#include <stddef.h>

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1

void * malloc(size_t size);
void * calloc(size_t nmemb, size_t size);
void * realloc(void * ptr, size_t size);
void   free(void * ptr);
void   abort(void);
int    atoi(const char * str);
long   strtol(const char * str, char ** endptr, int base);
long long strtoll(const char * str, char ** endptr, int base);
unsigned long strtoul(const char * str, char ** endptr, int base);
unsigned long long strtoull(const char * str, char ** endptr, int base);
double strtod(const char * str, char ** endptr);
int    abs(int x);

#endif
