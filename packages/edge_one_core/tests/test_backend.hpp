#pragma once

#include "engine.hpp"

#include <chrono>
#include <condition_variable>
#include <mutex>
#include <stdexcept>

using namespace edge_one;
using namespace std::chrono_literals;

struct Probe {
  std::mutex mutex;
  std::condition_variable condition;
  bool entered = false;
  bool released = false;
  bool block = false;
  bool fail = false;
  bool unavailable = false;
  std::atomic<int> destroyed{0};
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
