#ifndef EDGE_ONE_H
#define EDGE_ONE_H

#include <stdint.h>

#if defined(_WIN32) && defined(EDGE_ONE_BUILD)
#define EO_API __declspec(dllexport)
#elif defined(_WIN32)
#define EO_API __declspec(dllimport)
#else
#define EO_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#define EO_NOEXCEPT noexcept
#else
#define EO_NOEXCEPT
#endif

typedef struct eo_engine eo_engine;

enum eo_status {
  EO_STATUS_OK = 200,
  EO_STATUS_BUSY = 409,
  EO_STATUS_INVALID_REQUEST = 422,
  EO_STATUS_CANCELLED = 499,
  EO_STATUS_INTERNAL = 500,
  EO_STATUS_UNAVAILABLE = 503
};

/* model_path and manifest_json are NUL-terminated UTF-8. The caller/store must
 * keep the opened model backing object's bytes immutable and untruncated from
 * the start of eo_open until every engine using that object has been closed.
 * Publishers must stage replacements separately, never overwrite live backing
 * objects. This precondition is not enforced against other writers.
 * Native opening checks pinned model/readout identity, verifies and rewinds one
 * open file, and loads/maps that same file without reopening model_path. Name
 * replacement does not retarget that handle; same-inode writes/truncation are
 * unsupported and are not made safe by read-only mappings.
 * On failure returns NULL;
 * if err is non-NULL, *err is an owned error string (or NULL on allocation
 * failure). On success *err is NULL. Release error strings using eo_free. */
EO_API eo_engine *eo_open(const char *model_path, const char *manifest_json,
                          char **err) EO_NOEXCEPT;

/* Blocking; run off the UI thread. Returns owned JSON, released with eo_free.
 * On failure returns an error object; allocation failure can return NULL.
 * status is optional. One evaluation per engine; competing calls return BUSY.
 * Valid requests use pinned verdict scoring with exact sharing within the request.
 * Invalid requests or token budgets return INVALID_REQUEST; unavailable models return UNAVAILABLE.
 */
EO_API char *eo_evaluate(eo_engine *engine, const char *request_json, int32_t *status) EO_NOEXCEPT;

/* Thread-safe against an active evaluation. Idle cancellation has no effect on
 * the next evaluation. NULL is harmless. */
EO_API void eo_cancel(eo_engine *engine) EO_NOEXCEPT;

/* Destroys the handle. Caller must externally synchronize destruction:
 * prevent new calls, cancel if needed, and join ALL evaluate/cancel callers
 * BEFORE calling close. Close must not run concurrently with any other call.
 * Never reuse a closed handle. NULL is harmless. */
EO_API void eo_close(eo_engine *engine) EO_NOEXCEPT;

/* Frees an independently owned result/error. NULL is harmless. */
EO_API void eo_free(char *value) EO_NOEXCEPT;

#ifdef __cplusplus
}
#endif
#undef EO_NOEXCEPT
#endif
