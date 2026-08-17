/* Freestanding <math.h> for wasm3 (build glue, pattern of the Lua vendor's
   freestanding headers in libs/lua-5.4/include). Self-contained on purpose:
   the wasm3 sandbox module never sees another vendor's math.h. The
   double-precision functions below are provided by the kernel libc
   (src/kernel/libc.zig); the f32 variants lower to them. */
#ifndef __WASM3_MATH_H
#define __WASM3_MATH_H

#define NAN        (__builtin_nanf(""))
#define INFINITY   (__builtin_inff())

#define isnan(x)   __builtin_isnan(x)
#define isinf(x)   __builtin_isinf(x)
#define isfinite(x) __builtin_isfinite(x)
#define signbit(x) __builtin_signbit(x)

double fabs(double x);
double ceil(double x);
double floor(double x);
double trunc(double x);
double rint(double x);
double sqrt(double x);
double fmod(double x, double y);
double fmin(double a, double b);
double fmax(double a, double b);
double pow(double base, double exp);
double copysign(double a, double b);

static inline float fabsf(float x)   { return (float)fabs((double)x); }
static inline float ceilf(float x)   { return (float)ceil((double)x); }
static inline float floorf(float x)  { return (float)floor((double)x); }
static inline float truncf(float x)  { return (float)trunc((double)x); }
static inline float rintf(float x)   { return (float)rint((double)x); }
static inline float sqrtf(float x)   { return (float)sqrt((double)x); }
static inline float fmodf(float x, float y) { return (float)fmod((double)x, (double)y); }
static inline float copysignf(float a, float b) { return (float)copysign((double)a, (double)b); }

#endif
