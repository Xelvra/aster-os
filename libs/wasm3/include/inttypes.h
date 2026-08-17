/* Minimal <inttypes.h> for the freestanding kernel build: wasm3 includes it
   for the PRI* printf macros, but the kernel has no libc and Zig's own
   inttypes.h does an #include_next that fails without one. stdint.h comes
   from Zig's freestanding headers. */
#ifndef __KERNEL_INTTYPES_H
#define __KERNEL_INTTYPES_H

#include <stdint.h>

#define PRId32 "d"
#define PRId64 "lld"
#define PRIi32 "i"
#define PRIi64 "lli"
#define PRIu32 "u"
#define PRIu64 "llu"
#define PRIx32 "x"
#define PRIx64 "llx"
#define PRIX32 "X"
#define PRIX64 "llX"

#endif
