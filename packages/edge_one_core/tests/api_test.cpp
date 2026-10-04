#include "edge_one.h"
#include "engine.hpp"

#include <chrono>
#include <condition_variable>
#include <cstring>
#include <fstream>
#include <future>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <thread>

using namespace edge_one;
using namespace std::chrono_literals;
#define CHECK(condition)                                                                           \
  do {                                                                                             \
    if (!(condition))                                                                              \
      throw std::runtime_error(#condition);                                                        \
  } while (false)

struct Probe {
  std::mutex mutex;
  std::condition_variable condition;
  bool entered = false;
  bool released = false;
  bool block = false;
  bool fail = false;
  bool unavailable = false;
  int destroyed = 0;
};

// Only the test executable defines this backend; production never uses fake scores.
class TestBackend : public Backend {
public:
  explicit TestBackend(Probe &probe) : probe_(probe) {}
  ~TestBackend() override { ++probe_.destroyed; }
  Tokens encode(const std::string &value) override { return Tokens(value.size(), 1); }
  Distributions score(const RenderedRequest &request, const std::atomic<bool> &cancelled) override {
    {
      std::unique_lock<std::mutex> lock(probe_.mutex);
      probe_.entered = true;
      probe_.condition.notify_all();
      if (probe_.block) {
        const auto until = std::chrono::steady_clock::now() + 3s;
        while (!cancelled.load() && !probe_.released && std::chrono::steady_clock::now() < until)
          probe_.condition.wait_for(lock, 1ms);
        if (!cancelled.load() && !probe_.released)
          throw std::runtime_error("test barrier timed out");
      }
    }
    if (cancelled.load())
      throw Error(499, "Cancelled");
    if (probe_.fail)
      throw std::runtime_error("test failure");
    if (probe_.unavailable)
      throw Error(503, "Scorer unavailable");
    Distributions result;
    for (const auto &question : request.questions)
      result.emplace_back(question.names.size(), 1.0 / question.names.size());
    return result;
  }

private:
  Probe &probe_;
};

static const char *request =
    R"({"state":"s","model":"m","questions":{"q":{"type":"choice","criteria":{"a":null,"b":null}}}})";

static void wait_entered(Probe &probe) {
  std::unique_lock<std::mutex> lock(probe.mutex);
  CHECK(probe.condition.wait_for(lock, 3s, [&] { return probe.entered; }));
}

int main(int argc, char **argv) {
  try {
    CHECK(argc == 2);
    std::ifstream input(argv[1]);
    const std::string manifest_text((std::istreambuf_iterator<char>(input)), {});
    const auto manifest = parse_manifest(manifest_text.c_str());
    char *error = reinterpret_cast<char *>(1);
    CHECK(eo_open(nullptr, manifest_text.c_str(), &error) == nullptr);
    CHECK(error != nullptr && std::strlen(error) > 0);
    eo_free(error);
    CHECK(eo_open("/does/not/exist.gguf", "{}", &error) == nullptr);
    CHECK(error != nullptr);
    eo_free(error);
    CHECK(eo_open("/does/not/exist.gguf", manifest_text.c_str(), &error) == nullptr);
    CHECK(error != nullptr);
    eo_free(error);
    CHECK(eo_open("/does/not/exist.gguf", manifest_text.c_str(), nullptr) == nullptr);
    int32_t status = -1;
    char *result = eo_evaluate(nullptr, request, &status);
    CHECK(status == 503 && result != nullptr);
    CHECK(Json::parse(result).contains("error"));
    eo_free(result);
    eo_cancel(nullptr);
    eo_close(nullptr);
    eo_free(nullptr);

    Probe probe;
    eo_engine *engine = new eo_engine(manifest, std::make_unique<TestBackend>(probe));
    result = eo_evaluate(engine, "{", &status);
    CHECK(status == 422 && result != nullptr);
    eo_free(result);
    result = eo_evaluate(engine, nullptr, &status);
    CHECK(status == 422 && result != nullptr);
    eo_free(result);
    eo_cancel(engine); // Idle cancellation must not poison the next call.
    char *first = eo_evaluate(engine, request, &status);
    CHECK(status == 200 && first != nullptr);
    const std::string saved(first);
    CHECK(Json::parse(first)["answers"]["q"]["probabilities"]["a"] == 0.5);
    char *second = eo_evaluate(engine, request, nullptr);
    CHECK(second != first && saved == first);
    eo_free(second);

    probe.fail = true;
    result = eo_evaluate(engine, request, &status);
    CHECK(status == 500 && result != nullptr);
    eo_free(result);
    probe.fail = false;
    probe.unavailable = true;
    result = eo_evaluate(engine, request, &status);
    CHECK(status == 503 && result != nullptr);
    eo_free(result);
    probe.unavailable = false;

    probe.block = true;
    probe.entered = false;
    auto evaluation = std::async(std::launch::async, [&] {
      int32_t outcome = 0;
      char *output = eo_evaluate(engine, request, &outcome);
      eo_free(output);
      return outcome;
    });
    wait_entered(probe);
    result = eo_evaluate(engine, request, &status);
    CHECK(status == 409 && result != nullptr);
    eo_free(result);
    eo_cancel(engine);
    CHECK(evaluation.get() == 499);
    probe.block = false;
    result = eo_evaluate(engine, request, &status);
    CHECK(status == 200 && result != nullptr);
    eo_free(result);

    probe.block = true;
    probe.entered = false;
    auto closing_evaluation = std::async(std::launch::async, [&] {
      int32_t outcome = 0;
      char *output = eo_evaluate(engine, request, &outcome);
      eo_free(output);
      return outcome;
    });
    wait_entered(probe);
    eo_cancel(engine);
    CHECK(closing_evaluation.get() == 499);
    eo_close(engine);
    CHECK(probe.destroyed == 1);
    CHECK(saved == first); // Response memory survives engine close.
    eo_free(first);

    for (int i = 0; i < 50; ++i) {
      auto *repeated = new eo_engine(manifest, std::make_unique<TestBackend>(probe));
      eo_close(repeated);
    }
    CHECK(probe.destroyed == 51);
    std::cout << "C ABI, status, ownership and cancellation tests passed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
