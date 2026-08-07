#ifndef FREESTANDING_STDLIB_H
#define FREESTANDING_STDLIB_H

#include <stddef.h>

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1

int abs(int n);
long labs(long n);
long long llabs(long long n);

long strtol(const char *str, char **endptr, int base);
long long strtoll(const char *str, char **endptr, int base);
unsigned long strtoul(const char *str, char **endptr, int base);
unsigned long long strtoull(const char *str, char **endptr, int base);
double strtod(const char *str, char **endptr);
float strtof(const char *str, char **endptr);
long double strtold(const char *str, char **endptr);

void *malloc(size_t size);
void *calloc(size_t nmemb, size_t size);
void *realloc(void *ptr, size_t size);
void free(void *ptr);

int atoi(const char *str);
void abort(void);

#endif
