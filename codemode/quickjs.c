/* Fixed interpreter guest. No qjs CLI, quickjs-libc or host WASI linkage. */
#include "quickjs.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <wasi/api.h>

#define LIMIT 65536
#define IMPORT(name) __attribute__((import_module("max_v1"), import_name(name)))
IMPORT("input_size") extern int32_t input_size(void);
IMPORT("input_read") extern int32_t input_read(uint32_t, uint32_t, uint32_t);
IMPORT("output_write") extern void output_write(uint32_t, uint32_t);
IMPORT("tool_call") extern int32_t tool_call(uint32_t, uint32_t, uint32_t, uint32_t);

/* Libc is an allocator/string/math implementation, not an ambient capability.
   These internal stubs resolve its diagnostic/clock paths. The build checks
   the final import section; a new libc dependency fails closed. */
int gettimeofday(struct timeval *tv, void *tz) {
  (void)tz; tv->tv_sec = 0; tv->tv_usec = 0; return 0;
}
int clock_gettime(clockid_t clock, struct timespec *ts) {
  (void)clock; ts->tv_sec = 0; ts->tv_nsec = 0; return 0;
}
__wasi_errno_t __wasi_fd_write(__wasi_fd_t fd, const __wasi_ciovec_t *iov,
                              size_t len, __wasi_size_t *written) {
  (void)fd; (void)iov; (void)len; *written = 0; return __WASI_ERRNO_NOTCAPABLE;
}
__wasi_errno_t __wasi_fd_close(__wasi_fd_t fd) {
  (void)fd; return __WASI_ERRNO_NOTCAPABLE;
}
__wasi_errno_t __wasi_fd_fdstat_get(__wasi_fd_t fd, __wasi_fdstat_t *stat) {
  (void)fd; (void)stat; return __WASI_ERRNO_NOTCAPABLE;
}
__wasi_errno_t __wasi_fd_seek(__wasi_fd_t fd, __wasi_filedelta_t offset,
                             __wasi_whence_t whence, __wasi_filesize_t *result) {
  (void)fd; (void)offset; (void)whence; (void)result; return __WASI_ERRNO_NOTCAPABLE;
}
__wasi_errno_t __wasi_environ_sizes_get(__wasi_size_t *count, __wasi_size_t *size) {
  *count = 0; *size = 0; return 0;
}
__wasi_errno_t __wasi_environ_get(uint8_t **env, uint8_t *buffer) {
  (void)env; (void)buffer; return 0;
}
_Noreturn void __wasi_proc_exit(__wasi_exitcode_t code) {
  (void)code; __builtin_trap();
}

static void write_bytes(const char *bytes, size_t size) {
  output_write((uint32_t)(uintptr_t)bytes, (uint32_t)size);
}

static _Noreturn void fail(JSContext *ctx, JSValue error) {
  const char *message = JS_ToCString(ctx, error);
  JSValue report = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, report, "error",
                    JS_NewStringLen(ctx, message ? message : "JavaScript exception",
                                    message ? strnlen(message, 4096) : 20));
  JSValue json = JS_JSONStringify(ctx, report, JS_UNDEFINED, JS_UNDEFINED);
  size_t size;
  const char *bytes = JS_ToCStringLen(ctx, &size, json);
  if (bytes && size <= LIMIT) write_bytes(bytes, size);
  __builtin_trap();
}

static JSValue host_call(JSContext *ctx, JSValueConst self, int argc, JSValueConst *argv) {
  (void)self;
  if (argc != 1) return JS_ThrowTypeError(ctx, "one JSON request required");
  size_t size;
  const char *request = JS_ToCStringLen(ctx, &size, argv[0]);
  if (!request) return JS_EXCEPTION;
  if (size > LIMIT) {
    JS_FreeCString(ctx, request);
    return JS_ThrowRangeError(ctx, "tool request exceeds 64 KiB");
  }
  char reply[LIMIT];
  int32_t len = tool_call((uint32_t)(uintptr_t)request, (uint32_t)size,
                          (uint32_t)(uintptr_t)reply, sizeof(reply));
  JS_FreeCString(ctx, request);
  if (len < 0 || len > LIMIT) return JS_ThrowInternalError(ctx, "invalid host reply");
  return JS_NewStringLen(ctx, reply, len);
}

typedef struct rejection {
  JSValue promise, reason;
  struct rejection *next;
} rejection;

static void track_rejection(JSContext *ctx, JSValueConst promise, JSValueConst reason,
                             bool handled, void *opaque) {
  rejection **head = opaque;
  rejection **at = head;
  while (*at && JS_VALUE_GET_PTR((*at)->promise) != JS_VALUE_GET_PTR(promise)) at = &(*at)->next;
  if (handled && *at) {
    rejection *old = *at;
    *at = old->next;
    JS_FreeValue(ctx, old->promise);
    JS_FreeValue(ctx, old->reason);
    free(old);
  } else if (!handled && !*at) {
    rejection *entry = malloc(sizeof(*entry));
    if (!entry) __builtin_trap();
    *entry = (rejection){JS_DupValue(ctx, promise), JS_DupValue(ctx, reason), *head};
    *head = entry;
  }
}

void _start(void) {
  int32_t size = input_size();
  if (size <= 0 || size > 1024 * 1024) __builtin_trap();
  char *source = malloc((size_t)size + 1);
  if (!source) __builtin_trap();
  if (input_read(0, (uint32_t)(uintptr_t)source, (uint32_t)size) != size) __builtin_trap();
  source[size] = 0;
  JSRuntime *runtime = JS_NewRuntime();
  if (!runtime) __builtin_trap();
  JS_SetMemoryLimit(runtime, 48 * 1024 * 1024);
  JS_SetMaxStackSize(runtime, 256 * 1024);
  JSContext *ctx = JS_NewContext(runtime);
  if (!ctx) __builtin_trap();
  rejection *unhandled = NULL;
  JS_SetHostPromiseRejectionTracker(runtime, track_rejection, &unhandled);
  JSValue global = JS_GetGlobalObject(ctx);
  JS_SetPropertyStr(ctx, global, "__maxCall", JS_NewCFunction(ctx, host_call, "__maxCall", 1));
  JS_FreeValue(ctx, global);
  JSValue result = JS_Eval(ctx, source, (size_t)size, "<codemode>", JS_EVAL_TYPE_GLOBAL);
  free(source);
  if (JS_IsException(result)) fail(ctx, JS_GetException(ctx));
  if (JS_IsPromise(result)) {
    JS_PromiseMarkAsHandled(ctx, result);
    /* No timers or external events: pending with no jobs cannot make progress.
       Drain jobs before publication so queued effects/errors are not dropped. */
    JSContext *job_ctx;
    int status;
    while ((status = JS_ExecutePendingJob(runtime, &job_ctx)) > 0) {}
    if (status < 0) fail(job_ctx, JS_GetException(job_ctx));
    JSPromiseStateEnum state = JS_PromiseState(ctx, result);
    if (state == JS_PROMISE_PENDING) fail(ctx, JS_NewString(ctx, "unresolved promise: no external event loop"));
    JSValue value = JS_PromiseResult(ctx, result);
    JS_FreeValue(ctx, result);
    result = value;
    if (state == JS_PROMISE_REJECTED) fail(ctx, result);
  }
  if (unhandled) fail(ctx, unhandled->reason);
  if (JS_IsUndefined(result)) result = JS_NULL;
  JSValue json = JS_JSONStringify(ctx, result, JS_UNDEFINED, JS_UNDEFINED);
  if (JS_IsException(json)) fail(ctx, JS_GetException(ctx));
  if (JS_IsUndefined(json)) fail(ctx, JS_NewString(ctx, "return value must be JSON serializable"));
  size_t output_size;
  const char *output = JS_ToCStringLen(ctx, &output_size, json);
  if (!output) fail(ctx, JS_GetException(ctx));
  if (output_size > LIMIT) fail(ctx, JS_NewString(ctx, "return value exceeds 64 KiB; select or aggregate results"));
  write_bytes(output, output_size);
  JS_FreeCString(ctx, output);
  JS_FreeValue(ctx, json);
  JS_FreeValue(ctx, result);
  JS_FreeContext(ctx);
  JS_FreeRuntime(runtime);
}
