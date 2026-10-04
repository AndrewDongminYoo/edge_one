#include "engine.hpp"
#include <llama.h>

#include <limits>
#include <utility>

namespace edge_one {
namespace {
struct BackendRuntime {
  BackendRuntime() { llama_backend_init(); }
  ~BackendRuntime() { llama_backend_free(); }
};

class LlamaBackend final : public Backend {
public:
  LlamaBackend(const char *path, const Manifest &manifest) {
    static BackendRuntime runtime;
    auto params = llama_model_default_params();
    params.load_mode = LLAMA_LOAD_MODE_MMAP;
    params.n_gpu_layers = 0; // Linux CPU baseline; platform tuning follows bindings.
    model_.reset(llama_model_load_from_file(path, params));
    if (!model_)
      throw Error(503, "Unable to load local GGUF model");
    vocab_ = llama_model_get_vocab(model_.get());
    if (!vocab_ || encode(" yes") != Tokens{manifest.yes} || encode(" no") != Tokens{manifest.no} ||
        encode(" ->") != Tokens{manifest.verdict})
      throw Error(503, "Model vocabulary does not match manifest readout tokens");
    if (manifest.n_ctx > llama_model_n_ctx_train(model_.get()))
      throw Error(503, "Manifest context exceeds model context");
    auto context_params = llama_context_default_params();
    context_params.n_ctx = static_cast<uint32_t>(manifest.n_ctx);
    context_params.n_batch = 1024;
    context_params.n_ubatch = 1024; // The M0 exact-mode microbatch boundary.
    context_params.n_seq_max = 1;
    context_params.n_threads = 2;
    context_params.n_threads_batch = 2;
    context_.reset(llama_init_from_model(model_.get(), context_params));
    if (!context_)
      throw Error(503, "Unable to allocate model context");
  }

  Tokens encode(const std::string &text) override {
    if (text.size() > static_cast<size_t>(std::numeric_limits<int32_t>::max()))
      throw Error(422, "Text exceeds tokenizer input range");
    const auto size = static_cast<int32_t>(text.size());
    const auto needed = llama_tokenize(vocab_, text.data(), size, nullptr, 0, false, false);
    if (needed == std::numeric_limits<int32_t>::min())
      throw Error(422, "Tokenizer size overflow");
    if (needed == 0)
      return {};
    if (needed > 0)
      throw Error(503, "Unexpected tokenizer capacity result");
    Tokens tokens(static_cast<size_t>(-needed));
    const auto count =
        llama_tokenize(vocab_, text.data(), size, tokens.data(), -needed, false, false);
    if (count < 0 || count > -needed)
      throw Error(503, "Tokenizer failed");
    tokens.resize(static_cast<size_t>(count));
    return tokens;
  }

  Distributions score(const RenderedRequest &, const std::atomic<bool> &cancelled) override {
    if (cancelled.load())
      throw Error(499, "Evaluation cancelled");
    // Issue #9 supplies the verified verdict scorer. Never invent probabilities.
    throw Error(503, "Verdict scorer is not implemented; pending issue #9");
  }

private:
  std::unique_ptr<llama_model, decltype(&llama_model_free)> model_{nullptr, llama_model_free};
  std::unique_ptr<llama_context, decltype(&llama_free)> context_{nullptr, llama_free};
  const llama_vocab *vocab_ = nullptr;
};
} // namespace

std::unique_ptr<Backend> open_backend(const char *path, const Manifest &manifest) {
  return std::make_unique<LlamaBackend>(path, manifest);
}
} // namespace edge_one
