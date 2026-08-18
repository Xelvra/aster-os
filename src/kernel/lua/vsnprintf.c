/*
** Freestanding formatting for the Lua runtime. A minimal snprintf/
** vsnprintf/fprintf used only by the integer->string and number->string
** conversions inside Lua and by luaL_tolstring. No libc dependency.
*/

#include <stdarg.h>
#include <stddef.h>

typedef struct __file_handle FILE;

static void putc_buf(char *out, size_t size, size_t *pos, char c) {
    if (out != NULL && *pos < size)
        out[*pos] = c;
    (*pos)++;
}

static void puts_buf(char *out, size_t size, size_t *pos, const char *s) {
    while (*s)
        putc_buf(out, size, pos, *s++);
}

static void put_unsigned(char *out, size_t size, size_t *pos,
                         unsigned long long v, unsigned base, int upper) {
    char buf[24];
    int n = 0;
    if (v == 0) {
        putc_buf(out, size, pos, '0');
        return;
    }
    while (v > 0) {
        unsigned d = (unsigned)(v % base);
        buf[n++] = (d < 10) ? (char)('0' + d)
                            : (char)((upper ? 'A' : 'a') + (d - 10));
        v /= base;
    }
    while (n > 0)
        putc_buf(out, size, pos, buf[--n]);
}

static void put_double(char *out, size_t size, size_t *pos, double value, int prec) {
    if (prec < 0)
        prec = 6;
    if (prec > 9)
        prec = 9;
    char tmp[64];
    char *fmt = (char *)"%.0f";
    switch (prec) {
        case 1: fmt = (char *)"%.1f"; break;
        case 2: fmt = (char *)"%.2f"; break;
        case 3: fmt = (char *)"%.3f"; break;
        case 4: fmt = (char *)"%.4f"; break;
        case 5: fmt = (char *)"%.5f"; break;
        case 6: fmt = (char *)"%.6f"; break;
        case 7: fmt = (char *)"%.7f"; break;
        case 8: fmt = (char *)"%.8f"; break;
        case 9: fmt = (char *)"%.9f"; break;
        default: fmt = (char *)"%.0f"; break;
    }
    /* build the integer and fractional parts manually to avoid libc */
    int neg = 0;
    unsigned long long whole;
    if (value < 0) {
        neg = 1;
        value = -value;
    }
    whole = (unsigned long long)value;
    double frac = value - (double)whole;
    if (neg)
        putc_buf(out, size, pos, '-');
    put_unsigned(out, size, pos, whole, 10, 0);
    if (prec > 0) {
        putc_buf(out, size, pos, '.');
        int i;
        for (i = 0; i < prec; i++) {
            frac *= 10.0;
            int d = (int)frac;
            putc_buf(out, size, pos, (char)('0' + d));
            frac -= (double)d;
        }
    }
    (void)fmt;
    (void)tmp;
}

int vsnprintf(char *str, size_t size, const char *format, va_list ap) {
    size_t pos = 0;
    const char *p = format;
    while (*p) {
        if (*p != '%') {
            putc_buf(str, size, &pos, *p++);
            continue;
        }
        p++;
        if (*p == '%') {
            putc_buf(str, size, &pos, '%');
            p++;
            continue;
        }
        int left = 0, zero = 0, width = 0;
        while (*p == '-' || *p == '0' || *p == '+') {
            if (*p == '-') left = 1;
            else if (*p == '0') zero = 1;
            p++;
        }
        while (*p >= '0' && *p <= '9') {
            width = width * 10 + (*p - '0');
            p++;
        }
        int prec = 6;
        if (*p == '.') {
            p++;
            prec = 0;
            while (*p >= '0' && *p <= '9') {
                prec = prec * 10 + (*p - '0');
                p++;
            }
        }
        if (*p == 'l') { p++; if (*p == 'l') p++; }
        else if (*p == 'h') { p++; if (*p == 'h') p++; }
        else if (*p == 'z') p++;

        char spec = *p++;
        size_t start = pos;
        switch (spec) {
            case 'd': case 'i': {
                long long v = va_arg(ap, long long);
                if (v < 0) {
                    putc_buf(str, size, &pos, '-');
                    put_unsigned(str, size, &pos, (unsigned long long)(-(v + 1)) + 1, 10, 0);
                } else {
                    put_unsigned(str, size, &pos, (unsigned long long)v, 10, 0);
                }
                break;
            }
            case 'u':
                put_unsigned(str, size, &pos, va_arg(ap, unsigned long long), 10, 0);
                break;
            case 'x': case 'X':
                put_unsigned(str, size, &pos, va_arg(ap, unsigned long long), 16, spec == 'X');
                break;
            case 'o':
                put_unsigned(str, size, &pos, va_arg(ap, unsigned long long), 8, 0);
                break;
            case 'c': {
                int c = va_arg(ap, int);
                putc_buf(str, size, &pos, (char)c);
                break;
            }
            case 's': {
                const char *s = va_arg(ap, const char *);
                if (s == NULL) s = "(null)";
                puts_buf(str, size, &pos, s);
                break;
            }
            case 'p': {
                void *ptr = va_arg(ap, void *);
                puts_buf(str, size, &pos, "0x");
                put_unsigned(str, size, &pos, (unsigned long long)(unsigned long)ptr, 16, 0);
                break;
            }
            case 'f': case 'F': case 'g': case 'G': case 'e': case 'E': {
                double v = va_arg(ap, double);
                put_double(str, size, &pos, v, prec);
                break;
            }
            default:
                putc_buf(str, size, &pos, '%');
                putc_buf(str, size, &pos, spec);
                break;
        }
        size_t written = pos - start;
        if (width > 0 && written < (size_t)width) {
            size_t pad = (size_t)width - written;
            if (!left) {
                size_t i;
                for (i = 0; i < pad; i++) {
                    if (str != NULL && start + i < size)
                        str[start + i] = zero ? '0' : ' ';
                }
                if (str != NULL) {
                    for (i = 0; i < written; i++) {
                        if (start + pad + i < size)
                            str[start + pad + i] = str[start + i];
                    }
                }
            }
        }
    }
    if (str != NULL && size > 0) {
        if (pos < size)
            str[pos] = '\0';
        else
            str[size - 1] = '\0';
    }
    return (int)pos;
}

int snprintf(char *str, size_t size, const char *format, ...) {
    va_list ap;
    va_start(ap, format);
    int n = vsnprintf(str, size, format, ap);
    va_end(ap);
    return n;
}

int sprintf(char *str, const char *format, ...) {
    va_list ap;
    va_start(ap, format);
    int n = vsnprintf(str, 0x7fffffff, format, ap);
    va_end(ap);
    return n;
}

extern void lua_serial_write(unsigned char c);

static void writeserial(const char *s, int n) {
    int i;
    for (i = 0; i < n; i++)
        lua_serial_write((unsigned char)s[i]);
}

int fprintf(FILE *stream, const char *format, ...) {
    char buf[256];
    va_list ap;
    va_start(ap, format);
    int n = vsnprintf(buf, sizeof(buf), format, ap);
    va_end(ap);
    (void)stream;
    writeserial(buf, n);
    return n;
}
