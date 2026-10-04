#include "engine.hpp"

#include <cstdlib>
#include <cstring>
#include <new>

namespace {
char *owned(const char *value) noexcept {
  const auto size = std::strlen(value) + 1;
  auto *memory = static_cast<char *>(std::malloc(size));
  if (memory)
    std::memcpy(memory, value, size);
  return memory;
}

char *owned(const std::string &value) noexcept { return owned(value.c_str()); }

char *failure(int32_t code, const char *message, int32_t *status) noexcept {
  if (status)
    *status = code;
  try {
    auto *result =
        owned(edge_one::Json({{"error", {{"status", code}, {"message", message}}}}).dump());
    if (!result && status)
      *status = EO_STATUS_UNAVAILABLE;
    return result;
  } catch (...) {
    if (status)
      *status = EO_STATUS_UNAVAILABLE;
    return nullptr;
  }
}

class Evaluation {
public:
  explicit Evaluation(eo_engine &engine) : engine_(engine) {
    std::lock_guard<std::mutex> lock(engine_.mutex);
    if (engine_.closing)
      throw edge_one::Error(EO_STATUS_UNAVAILABLE, "Engine is closing");
    if (engine_.active)
      throw edge_one::Error(EO_STATUS_BUSY, "Engine is already evaluating");
    engine_.cancelled.store(false);
    engine_.active = true;
  }
  ~Evaluation() {
    std::lock_guard<std::mutex> lock(engine_.mutex);
    engine_.active = false;
    engine_.idle.notify_all();
  }

private:
  eo_engine &engine_;
};

void check_cancelled(const eo_engine &engine) {
  if (engine.cancelled.load())
    throw edge_one::Error(EO_STATUS_CANCELLED, "Evaluation cancelled");
}
} // namespace

extern "C" {
eo_engine *eo_open(const char *model_path, const char *manifest_json, char **err) noexcept {
  if (err)
    *err = nullptr;
  try {
    if (!model_path || model_path[0] == '\0')
      throw edge_one::Error(503, "Model path is empty");
    auto manifest = edge_one::parse_manifest(manifest_json);
    auto backend = edge_one::open_backend(model_path, manifest);
    return new eo_engine(std::move(manifest), std::move(backend));
  } catch (const std::bad_alloc &) {
    if (err)
      *err = owned("Insufficient memory to open engine");
  } catch (const std::exception &error) {
    if (err)
      *err = owned(error.what());
  } catch (...) {
    if (err)
      *err = owned("Unexpected error opening engine");
  }
  return nullptr;
}

char *eo_evaluate(eo_engine *engine, const char *request_json, int32_t *status) noexcept {
  if (status)
    *status = EO_STATUS_UNAVAILABLE;
  if (!engine)
    return failure(EO_STATUS_UNAVAILABLE, "Engine is null", status);
  try {
    Evaluation evaluation(*engine);
    const auto request = edge_one::parse_json(request_json);
    check_cancelled(*engine);
    const auto rendered =
        edge_one::render_request(request, engine->manifest, [&](const std::string &text) {
          check_cancelled(*engine);
          return engine->backend->encode(text);
        });
    check_cancelled(*engine);
    const auto distributions = engine->backend->score(rendered, engine->cancelled);
    check_cancelled(*engine);
    auto *result = owned(edge_one::make_response(rendered, engine->manifest, distributions).dump());
    if (!result)
      return failure(EO_STATUS_UNAVAILABLE, "Insufficient response memory", status);
    if (status)
      *status = EO_STATUS_OK;
    return result;
  } catch (const edge_one::Error &error) {
    return failure(error.status, error.what(), status);
  } catch (const std::bad_alloc &) {
    return failure(EO_STATUS_UNAVAILABLE, "Insufficient evaluation memory", status);
  } catch (const std::exception &) {
    return failure(EO_STATUS_INTERNAL, "Unexpected evaluation error", status);
  } catch (...) {
    return failure(EO_STATUS_INTERNAL, "Unexpected native error", status);
  }
}

void eo_cancel(eo_engine *engine) noexcept {
  if (!engine)
    return;
  try {
    std::lock_guard<std::mutex> lock(engine->mutex);
    if (engine->active)
      engine->cancelled.store(true);
  } catch (...) { /* Never unwind across a C ABI. */
  }
}

void eo_close(eo_engine *engine) noexcept {
  if (!engine)
    return;
  try {
    {
      std::unique_lock<std::mutex> lock(engine->mutex);
      engine->closing = true;
      engine->cancelled.store(true);
      engine->idle.wait(lock, [&] { return !engine->active; });
    }
    delete engine;
  } catch (...) { /* If waiting fails, do not destroy an active engine. */
  }
}

void eo_free(char *value) noexcept { std::free(value); }
} // extern "C"
