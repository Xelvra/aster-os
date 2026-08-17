/* Freestanding <assert.h> for the wasm3 sandbox: wasm3's d_m3Assert is a
   no-op outside DEBUG/ASSERTS, so assert() here never fires. */
#ifndef __WASM3_ASSERT_H
#define __WASM3_ASSERT_H
#define assert(x) ((void)0)
#endif
