/* Freestanding <endian.h> for the kernel (no libc; see inttypes.h). The
   kernel-side wasm3 cimport takes wasm3's fallback bswap path that includes
   <endian.h>; provide the byte-order constants and the bswap macros. */
#ifndef __KERNEL_ENDIAN_H
#define __KERNEL_ENDIAN_H

#define __LITTLE_ENDIAN 1234
#define __BIG_ENDIAN    4321
#define __BYTE_ORDER    __LITTLE_ENDIAN
#define LITTLE_ENDIAN   __LITTLE_ENDIAN
#define BIG_ENDIAN      __BIG_ENDIAN
#define BYTE_ORDER      __BYTE_ORDER

#define __bswap_16(x) __builtin_bswap16((x))
#define __bswap_32(x) __builtin_bswap32((x))
#define __bswap_64(x) __builtin_bswap64((x))

#endif
