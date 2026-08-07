#ifndef FREESTANDING_STDIO_H
#define FREESTANDING_STDIO_H

#include <stddef.h>
#include <stdarg.h>

typedef struct __file_handle FILE;

#define EOF (-1)
#define BUFSIZ 1024

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

int snprintf(char *str, size_t size, const char *format, ...);
int vsnprintf(char *str, size_t size, const char *format, va_list ap);
int sprintf(char *str, const char *format, ...);

size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream);
int fflush(FILE *stream);
int fprintf(FILE *stream, const char *format, ...);
int vsnprintf(char *str, size_t size, const char *format, va_list ap);

FILE *fopen(const char *path, const char *mode);
FILE *freopen(const char *path, const char *mode, FILE *stream);
int fclose(FILE *stream);
int feof(FILE *stream);
int ferror(FILE *stream);
size_t fread(void *ptr, size_t size, size_t nmemb, FILE *stream);
int getc(FILE *stream);

#endif
