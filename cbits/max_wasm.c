#include "max_wasm.h"
#include <wasmtime.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

#define MESSAGE_LIMIT 65536

struct max_wasm {
  wasm_engine_t *engine;
  atomic_bool interrupted;
};

static void diagnostic(char *out, size_t capacity, const char *data, size_t len) {
  if (!capacity) return;
  if (len >= capacity) len = capacity - 1;
  memcpy(out, data, len);
  out[len] = 0;
}

static int failure(wasmtime_error_t *error, wasm_trap_t *trap,
                   char *out, size_t capacity) {
  wasm_name_t message;
  if (error) {
    wasmtime_error_message(error, &message);
    wasmtime_error_delete(error);
  } else {
    wasm_trap_message(trap, &message);
    wasm_trap_delete(trap);
  }
  diagnostic(out, capacity, message.data, message.size);
  wasm_byte_vec_delete(&message);
  return 1;
}

max_wasm *max_wasm_new(void) {
  max_wasm *run = calloc(1, sizeof(*run));
  if (!run) return NULL;
  atomic_init(&run->interrupted, false);
  wasm_config_t *config = wasm_config_new();
  wasmtime_config_consume_fuel_set(config, true);
  wasmtime_config_epoch_interruption_set(config, true);
  wasmtime_config_wasm_threads_set(config, false);
  wasmtime_config_max_wasm_stack_set(config, 512 * 1024);
  run->engine = wasm_engine_new_with_config(config);
  if (!run->engine) { free(run); return NULL; }
  return run;
}

void max_wasm_delete(max_wasm *run) {
  wasm_engine_delete(run->engine);
  free(run);
}

void max_wasm_interrupt(max_wasm *run) {
  atomic_store(&run->interrupted, true);
  wasmtime_engine_increment_epoch(run->engine);
}

static wasm_trap_t *trap_text(const char *text) {
  return wasmtime_trap_new(text, strlen(text));
}

/* Check all ranges, including reply capacity, before allowing a host effect.
   Conversion through uint32_t preserves Wasm's unsigned address semantics;
   subtraction avoids overflow in pointer + length. */
static bool in_bounds(size_t memory, uint32_t offset, uint32_t length) {
  return offset <= memory && length <= memory - offset;
}

typedef struct {
  max_wasm_tool_cb callback;
  void *context;
  const uint8_t *input;
  size_t input_length;
  uint8_t **output;
  size_t *output_length;
} host_callback;

static wasm_trap_t *guest_slice(wasmtime_caller_t *caller, uint32_t offset,
                                uint32_t length, size_t limit, uint8_t **bytes) {
  wasmtime_extern_t item;
  if (!wasmtime_caller_export_get(caller, "memory", 6, &item))
    return trap_text("max_v1 requires exported memory");
  if (item.kind != WASMTIME_EXTERN_MEMORY) {
    wasmtime_extern_delete(&item);
    return trap_text("max_v1 memory export is not a memory");
  }
  wasmtime_context_t *context = wasmtime_caller_context(caller);
  size_t size = wasmtime_memory_data_size(context, &item.of.memory);
  bool valid = length <= limit && in_bounds(size, offset, length);
  if (valid) *bytes = wasmtime_memory_data(context, &item.of.memory) + offset;
  wasmtime_extern_delete(&item);
  return valid ? NULL : trap_text("max_v1 invalid request or reply memory range");
}

static wasm_trap_t *tool_call(void *data, wasmtime_caller_t *caller,
                             const wasmtime_val_t *args, size_t nargs,
                             wasmtime_val_t *results, size_t nresults) {
  (void)nargs; (void)nresults;
  host_callback *host = data;
  uint32_t rp = (uint32_t)args[0].of.i32, rn = (uint32_t)args[1].of.i32;
  uint32_t wp = (uint32_t)args[2].of.i32, wn = (uint32_t)args[3].of.i32;
  if (!rn || !wn)
    return trap_text("max_v1 invalid request or reply memory range");
  uint8_t *request, *reply;
  wasm_trap_t *trap = guest_slice(caller, rp, rn, MESSAGE_LIMIT, &request);
  if (trap) return trap;
  trap = guest_slice(caller, wp, wn, MESSAGE_LIMIT, &reply);
  if (trap) return trap;
  int32_t length = host->callback(host->context, request, rn, reply, wn);
  if (length < 0 || (uint32_t)length > wn)
    return trap_text("max_v1 host stopped or reply exceeds capacity; do not replay effects");
  results[0].kind = WASMTIME_I32;
  results[0].of.i32 = length;
  return NULL;
}

static wasm_trap_t *input_size(void *data, wasmtime_caller_t *caller,
                               const wasmtime_val_t *args, size_t nargs,
                               wasmtime_val_t *results, size_t nresults) {
  (void)caller; (void)args; (void)nargs; (void)nresults;
  host_callback *host = data;
  results[0].kind = WASMTIME_I32;
  results[0].of.i32 = (int32_t)host->input_length;
  return NULL;
}

static wasm_trap_t *input_read(void *data, wasmtime_caller_t *caller,
                               const wasmtime_val_t *args, size_t nargs,
                               wasmtime_val_t *results, size_t nresults) {
  (void)nargs; (void)nresults;
  host_callback *host = data;
  uint32_t offset = (uint32_t)args[0].of.i32;
  uint32_t pointer = (uint32_t)args[1].of.i32, length = (uint32_t)args[2].of.i32;
  if (!in_bounds(host->input_length, offset, length))
    return trap_text("max_v1 invalid input range");
  uint8_t *bytes;
  wasm_trap_t *trap = guest_slice(caller, pointer, length, 1024 * 1024, &bytes);
  if (trap) return trap;
  memcpy(bytes, host->input + offset, length);
  results[0].kind = WASMTIME_I32;
  results[0].of.i32 = (int32_t)length;
  return NULL;
}

static wasm_trap_t *output_write(void *data, wasmtime_caller_t *caller,
                                 const wasmtime_val_t *args, size_t nargs,
                                 wasmtime_val_t *results, size_t nresults) {
  (void)nargs; (void)results; (void)nresults;
  host_callback *host = data;
  if (*host->output) return trap_text("max_v1 output already written");
  uint32_t pointer = (uint32_t)args[0].of.i32, length = (uint32_t)args[1].of.i32;
  uint8_t *bytes;
  wasm_trap_t *trap = guest_slice(caller, pointer, length, MESSAGE_LIMIT, &bytes);
  if (trap) return trap;
  *host->output = malloc(length ? length : 1);
  if (!*host->output) return trap_text("max_v1 could not allocate output");
  memcpy(*host->output, bytes, length);
  *host->output_length = length;
  return NULL;
}

static wasmtime_error_t *define_func(wasmtime_linker_t *linker, const char *name,
                                     size_t parameters, size_t returns,
                                     wasmtime_func_callback_t callback, host_callback *host) {
  wasm_valtype_vec_t p, r;
  wasm_valtype_vec_new_uninitialized(&p, parameters);
  wasm_valtype_vec_new_uninitialized(&r, returns);
  for (size_t i = 0; i < parameters; ++i) p.data[i] = wasm_valtype_new_i32();
  for (size_t i = 0; i < returns; ++i) r.data[i] = wasm_valtype_new_i32();
  wasm_functype_t *signature = wasm_functype_new(&p, &r);
  wasmtime_error_t *error = wasmtime_linker_define_func(linker, "max_v1", 6, name,
                                                       strlen(name), signature, callback, host, NULL);
  wasm_functype_delete(signature);
  return error;
}

int max_wasm_run(max_wasm *run, const uint8_t *bytes, size_t length,
                 uint64_t fuel, int64_t memory,
                 const uint8_t *input, size_t input_length, uint8_t **output, size_t *output_length,
                 max_wasm_tool_cb callback, void *callback_context,
                 char *message, size_t capacity) {
  *output = NULL;
  *output_length = 0;
  host_callback host = { callback, callback_context, input, input_length, output, output_length };
  wasmtime_module_t *module = NULL;
  wasmtime_store_t *store = NULL;
  wasmtime_linker_t *linker = NULL;
  wasm_trap_t *trap = NULL;
  wasmtime_error_t *error = NULL;
  int result = 1;
  error = wasmtime_module_new(run->engine, bytes, length, &module);
  if (error) goto failed;
  store = wasmtime_store_new(run->engine, NULL, NULL);
  wasmtime_store_limiter(store, memory, 10000, 1, 1, 1);
  wasmtime_context_t *context = wasmtime_store_context(store);
  error = wasmtime_context_set_fuel(context, fuel);
  if (error) goto failed;
  wasmtime_context_set_epoch_deadline(context, 1);
  /* A cancellation during compilation must not be lost when setting the
     relative deadline. The main thread also wakes blocked host callbacks. */
  if (atomic_load(&run->interrupted)) {
    diagnostic(message, capacity, "execution interrupted before instantiation", sizeof("execution interrupted before instantiation") - 1);
    goto cleanup;
  }
  linker = wasmtime_linker_new(run->engine);
  error = define_func(linker, "tool_call", 4, 1, tool_call, &host);
  if (error) goto failed;
  if (input) {
    error = define_func(linker, "input_size", 0, 1, input_size, &host);
    if (error) goto failed;
    error = define_func(linker, "input_read", 3, 1, input_read, &host);
    if (error) goto failed;
    error = define_func(linker, "output_write", 2, 0, output_write, &host);
    if (error) goto failed;
  }
  wasmtime_instance_t instance;
  error = wasmtime_linker_instantiate(linker, context, module, &instance, &trap);
  if (error || trap) goto failed;
  wasmtime_extern_t start;
  if (!wasmtime_instance_export_get(context, &instance, "_start", 6, &start)) {
    diagnostic(message, capacity, "missing _start export", 21);
    goto cleanup;
  }
  if (start.kind != WASMTIME_EXTERN_FUNC) {
    wasmtime_extern_delete(&start);
    diagnostic(message, capacity, "_start export is not a function", sizeof("_start export is not a function") - 1);
    goto cleanup;
  }
  error = wasmtime_func_call(context, &start.of.func, NULL, 0, NULL, 0, &trap);
  wasmtime_extern_delete(&start);
  if (error || trap) goto failed;
  result = 0;
  goto cleanup;
failed:
  result = failure(error, trap, message, capacity);
cleanup:
  if (linker) wasmtime_linker_delete(linker);
  if (store) wasmtime_store_delete(store);
  if (module) wasmtime_module_delete(module);
  return result;
}

/* WAT conversion is for deterministic fixtures and host-authored modules.
   Execution itself accepts only validated Wasm bytes, never native code. */
int max_wasm_wat(const uint8_t *bytes, size_t len, uint8_t **out, size_t *outlen,
                 char *message, size_t capacity) {
  wasm_byte_vec_t binary;
  wasmtime_error_t *error = wasmtime_wat2wasm((const char *)bytes, len, &binary);
  if (error) return failure(error, NULL, message, capacity);
  *out = malloc(binary.size);
  if (!*out) {
    wasm_byte_vec_delete(&binary);
    diagnostic(message, capacity, "allocation failed", 17);
    return 1;
  }
  *outlen = binary.size;
  memcpy(*out, binary.data, binary.size);
  wasm_byte_vec_delete(&binary);
  return 0;
}
void max_wasm_free(uint8_t *bytes) { free(bytes); }
