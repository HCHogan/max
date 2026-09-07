#ifndef MAX_WASM_H
#define MAX_WASM_H
#include <stddef.h>
#include <stdint.h>

/* No Haskell closures or Effectful environments cross this interface. */
typedef struct max_wasm max_wasm;
typedef int32_t (*max_wasm_tool_cb)(void *, const uint8_t *, size_t, uint8_t *, size_t);
max_wasm *max_wasm_new(void);
void max_wasm_delete(max_wasm *);
void max_wasm_interrupt(max_wasm *);
int max_wasm_run(max_wasm *, const uint8_t *, size_t, uint64_t, int64_t,
                 const uint8_t *, size_t, uint8_t **, size_t *,
                 max_wasm_tool_cb, void *, char *, size_t);
int max_wasm_wat(const uint8_t *, size_t, uint8_t **, size_t *, char *, size_t);
void max_wasm_free(uint8_t *);
#endif
