#include "test_backend.hpp"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <thread>

// This library links the real ABI and renderer with the existing test backend.
// It is built separately from the production build hook; never bundle it.
static Probe probe;
static std::atomic<int> evaluations{0}, cancellations{0}, closes{0}, owned{0}, violations{0};
static std::atomic<int> entered{0}, cancel_entered{0}, opens{0}, mode{0};
static std::atomic<bool> gate_evaluate{false}, gate_cancel{false};

extern "C" {
eo_engine *eo_real_open(const char *, const char *, char **) noexcept;
char *eo_real_evaluate(eo_engine *, const char *, int32_t *) noexcept;
void eo_real_cancel(eo_engine *) noexcept;
void eo_real_close(eo_engine *) noexcept;
void eo_real_free(char *) noexcept;
}

namespace edge_one {
std::unique_ptr<Backend> open_backend(const char *path, const Manifest &) {
  if (std::strcmp(path, "fail-open") == 0)
    throw Error(503, "Synthetic open failure");
  return std::make_unique<TestBackend>(probe);
}
} // namespace edge_one

static void wait_gate(const std::atomic<bool> &gate) {
  const auto deadline = std::chrono::steady_clock::now() + 5s;
  while (gate.load() && std::chrono::steady_clock::now() < deadline)
    std::this_thread::sleep_for(1ms);
}

extern "C" {
EO_API eo_engine *eo_open(const char *path, const char *manifest, char **error) noexcept {
  auto *engine = eo_real_open(path, manifest, error);
  if (engine)
    ++opens;
  if (error && *error)
    ++owned;
  return engine;
}
EO_API char *eo_evaluate(eo_engine *engine, const char *json, int32_t *status) noexcept {
  ++evaluations;
  ++entered;
  wait_gate(gate_evaluate);
  char *result = eo_real_evaluate(engine, json, status);
  if (mode >= 6) {
    eo_real_free(result);
    result = nullptr;
    if (mode == 7 || mode == 8) {
      result = static_cast<char *>(std::malloc(2));
      if (result) {
        result[0] = mode == 7 ? static_cast<char>(0xff) : '{';
        result[1] = '\0';
      }
    }
  }
  if (result)
    ++owned;
  --evaluations;
  return result;
}
EO_API void eo_cancel(eo_engine *engine) noexcept {
  ++cancellations;
  ++cancel_entered;
  wait_gate(gate_cancel);
  eo_real_cancel(engine);
  --cancellations;
}
EO_API void eo_close(eo_engine *engine) noexcept {
  if (evaluations.load() || cancellations.load())
    ++violations;
  ++closes;
  eo_real_close(engine);
}
EO_API void eo_free(char *value) noexcept {
  if (value)
    --owned;
  eo_real_free(value);
}

EO_API void eo_test_reset(int configuration) {
  mode = configuration;
  opens = 0;
  probe.entered = false;
  probe.released = false;
  probe.block = mode == 1 || mode == 4 || mode == 5;
  probe.fail = mode == 2;
  probe.unavailable = mode == 3;
  probe.destroyed = 0;
  entered = 0;
  cancel_entered = 0;
  closes = 0;
  violations = 0;
  owned = 0;
  gate_evaluate = mode == 4;
  gate_cancel = mode == 5;
}
EO_API int eo_test_read(int key) {
  switch (key) {
  case 0:
    return entered.load();
  case 1:
    return cancel_entered.load();
  case 2:
    return closes.load();
  case 3:
    return owned.load();
  case 4:
    return violations.load();
  case 5:
    return evaluations.load() + cancellations.load();
  case 6:
    return probe.destroyed.load();
  case 8:
    return opens.load();
  case 7: {
    std::lock_guard<std::mutex> lock(probe.mutex);
    return probe.entered;
  }
  default:
    return -1;
  }
}
EO_API void eo_test_release(int key) {
  if (key == 0)
    gate_evaluate = false;
  if (key == 1)
    gate_cancel = false;
  if (key == 3) {
    std::lock_guard<std::mutex> lock(probe.mutex);
    probe.released = true;
    probe.condition.notify_all();
  }
  if (key == 2) {
    std::lock_guard<std::mutex> lock(probe.mutex);
    probe.block = false;
  }
}
}
