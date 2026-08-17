/* Freestanding <inttypes.h> for the kernel. The clang inttypes.h does an
   unconditional #include_next that needs a hosted libc, so the kernel ships
   its own printf macros; the integer types come from <stdint.h>. This lets
   the kernel-side wasm3 cimport (src/kernel/wasm/cimport.zig) compile. */
#ifndef __KERNEL_INTTYPES_H
#define __KERNEL_INTTYPES_H

#include <stdint.h>

#define PRId8   "hhd"
#define PRId16  "hd"
#define PRId32  "d"
#define PRId64  "lld"
#define PRIi8   "hhi"
#define PRIi16  "hi"
#define PRIi32  "i"
#define PRIi64  "lli"
#define PRIu8   "hhu"
#define PRIu16  "hu"
#define PRIu32  "u"
#define PRIu64  "llu"
#define PRIx8   "hhx"
#define PRIx16  "hx"
#define PRIx32  "x"
#define PRIx64  "llx"
#define PRIX64  "llX"
#define PRIdPTR "ld"
#define PRIuPTR "lu"
#define PRIxPTR "lx"

#endif
