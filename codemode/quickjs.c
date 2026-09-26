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

static JSRuntime *runtime;
static JSContext *ctx;
static JSValue result, take, settle;
static rejection *unhandled;
static int suspended;

static char *read_input(int32_t limit, int32_t *size) {
  *size = input_size();
  if (*size <= 0 || *size > limit) __builtin_trap();
  char *bytes = malloc((size_t)*size + 1);
  if (!bytes) __builtin_trap();
  if (input_read(0, (uint32_t)(uintptr_t)bytes, (uint32_t)*size) != *size) __builtin_trap();
  bytes[*size] = 0;
  return bytes;
}

static void emit(JSValue value, size_t limit) {
  JSValue json = JS_JSONStringify(ctx, value, JS_UNDEFINED, JS_UNDEFINED);
  if (JS_IsException(json)) fail(ctx, JS_GetException(ctx));
  if (JS_IsUndefined(json)) fail(ctx, JS_NewString(ctx, "return value must be JSON serializable"));
  size_t size;
  const char *bytes = JS_ToCStringLen(ctx, &size, json);
  if (!bytes) fail(ctx, JS_GetException(ctx));
  if (size > limit) fail(ctx, JS_NewString(ctx, "return value exceeds 64 KiB; select or aggregate results"));
  write_bytes(bytes, size);
  JS_FreeCString(ctx, bytes);
  JS_FreeValue(ctx, json);
  JS_FreeValue(ctx, value);
}

static void drain(void) {
  JSContext *job_ctx;
  int status;
  while ((status = JS_ExecutePendingJob(runtime, &job_ctx)) > 0) {}
  if (status < 0) fail(job_ctx, JS_GetException(job_ctx));
  if (unhandled) fail(ctx, unhandled->reason);
  JSPromiseStateEnum state = JS_IsPromise(result) ? JS_PromiseState(ctx, result) : JS_PROMISE_FULFILLED;
  if (state != JS_PROMISE_PENDING) {
    JSValue value = JS_IsPromise(result) ? JS_PromiseResult(ctx, result) : JS_DupValue(ctx, result);
    if (state == JS_PROMISE_REJECTED) fail(ctx, value);
    if (JS_IsUndefined(value)) value = JS_NULL;
    JSValue report = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, report, "done", value);
    emit(report, LIMIT + 9); /* {"done":...} framing is not the return value. */
    return;
  }
  JSValue calls = JS_Call(ctx, take, JS_UNDEFINED, 0, NULL);
  if (JS_IsException(calls)) fail(ctx, JS_GetException(ctx));
  JSValue count = JS_GetPropertyStr(ctx, calls, "waiting");
  int32_t waiting;
  if (JS_ToInt32(ctx, &waiting, count) || waiting <= 0)
    fail(ctx, JS_NewString(ctx, "unresolved promise: nothing left to wait for"));
  JS_FreeValue(ctx, count);
  suspended = 1;
  emit(calls, 16 * 1024 * 1024);
}

void start(void) {
  if (runtime) __builtin_trap();
  int32_t size;
  char *source = read_input(1024 * 1024, &size);
  runtime = JS_NewRuntime();
  if (!runtime) __builtin_trap();
  JS_SetMemoryLimit(runtime, 192 * 1024 * 1024);
  JS_SetMaxStackSize(runtime, 256 * 1024);
  ctx = JS_NewContext(runtime);
  if (!ctx) __builtin_trap();
  JS_SetHostPromiseRejectionTracker(runtime, track_rejection, &unhandled);
  result = JS_Eval(ctx, source, (size_t)size, "<codemode>", JS_EVAL_TYPE_GLOBAL);
  free(source);
  if (JS_IsException(result)) fail(ctx, JS_GetException(ctx));
  JSValue global = JS_GetGlobalObject(ctx);
  take = JS_GetPropertyStr(ctx, global, "__maxTake");
  settle = JS_GetPropertyStr(ctx, global, "__maxSettle");
  JS_FreeValue(ctx, global);
  if (!JS_IsFunction(ctx, take) || !JS_IsFunction(ctx, settle))
    fail(ctx, JS_NewString(ctx, "SDK event loop missing"));
  if (JS_IsPromise(result)) JS_PromiseMarkAsHandled(ctx, result);
  drain();
}

void resume(void) {
  if (!suspended) __builtin_trap();
  suspended = 0;
  int32_t size;
  char *bytes = read_input(16 * 1024 * 1024, &size);
  JSValue outcomes = JS_ParseJSON(ctx, bytes, (size_t)size, "<outcomes>");
  free(bytes);
  if (JS_IsException(outcomes)) fail(ctx, JS_GetException(ctx));
  JSValue settled = JS_Call(ctx, settle, JS_UNDEFINED, 1, &outcomes);
  JS_FreeValue(ctx, outcomes);
  if (JS_IsException(settled)) fail(ctx, JS_GetException(ctx));
  JS_FreeValue(ctx, settled);
  drain();
}
