#include "engine.hpp"
#include "integrity.hpp"
#include "model_loader.hpp"
#include "scorer.hpp"
#include <llama.h>

#include <algorithm>
#include <limits>
#include <utility>

namespace edge_one {
namespace {
struct BackendRuntime {
  BackendRuntime() { llama_backend_init(); }
  ~BackendRuntime() { llama_backend_free(); }
};

class LlamaBackend final : public Backend, private Decoder {
public:
  LlamaBackend(const char *path, const Manifest &manifest, ScoreMode mode,
               ScoreDiagnostics *diagnostics, Json *profile)
      : manifest_(manifest), mode_(mode), diagnostics_(diagnostics) {
    validate_pinned_manifest(manifest);
    static BackendRuntime runtime;
    auto params = llama_model_default_params();
    params.load_mode = LLAMA_LOAD_MODE_MMAP;
    params.n_gpu_layers = 0; // Linux CPU baseline; platform tuning follows bindings.
    model_ = std::make_unique<VerifiedModel>(path, manifest.sha256, manifest.bytes, params);
    vocab_ = llama_model_get_vocab(model_->get());
    if (!vocab_ || encode(" yes") != Tokens{manifest.yes} || encode(" no") != Tokens{manifest.no} ||
        encode(" ->") != Tokens{manifest.verdict})
      throw Error(503, "Model vocabulary does not match manifest readout tokens");
    if (manifest.n_ctx > llama_model_n_ctx_train(model_->get()))
      throw Error(503, "Manifest context exceeds model context");
    auto context_params = llama_context_default_params();
    context_params.n_ctx = static_cast<uint32_t>(manifest.n_ctx);
    context_params.n_batch = static_cast<uint32_t>(manifest.n_ctx);
    context_params.n_ubatch = std::min(1024u, context_params.n_batch);
    context_params.n_seq_max = 2;
    context_params.n_outputs_max = 26;
    context_params.n_outputs_max_per_seq = 26;
    context_params.kv_unified = true;
    context_params.n_threads = 2;
    context_params.n_threads_batch = 2;
    context_params.no_perf = true;
    context_params.offload_kqv = false;
    context_params.op_offload = false;
    context_.reset(llama_init_from_model(model_->get(), context_params));
    if (!context_)
      throw Error(503, "Unable to allocate model context");
    if (llama_n_batch(context_.get()) < static_cast<uint32_t>(manifest.n_ctx) ||
        llama_n_ctx_seq(context_.get()) < static_cast<uint32_t>(manifest.n_ctx))
      throw Error(503, "Model context cannot fit the runtime token budget");
    if (profile)
      *profile = {{"n_ctx", llama_n_ctx(context_.get())},
                  {"n_ctx_seq", llama_n_ctx_seq(context_.get())},
                  {"n_batch", llama_n_batch(context_.get())},
                  {"n_ubatch", llama_n_ubatch(context_.get())},
                  {"n_seq_max", llama_n_seq_max(context_.get())},
                  {"n_outputs_max", context_params.n_outputs_max},
                  {"threads", llama_n_threads(context_.get())},
                  {"threads_batch", llama_n_threads_batch(context_.get())},
                  {"kv_unified", context_params.kv_unified},
                  {"n_gpu_layers", 0},
                  {"offload_kqv", false},
                  {"op_offload", false},
                  {"flash_attn", "auto"}};
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

  Distributions score(const RenderedRequest &request, const std::atomic<bool> &cancelled) override {
    struct AbortState {
      const std::atomic<bool> &cancelled;
    } state{cancelled};
    struct ResetCallback {
      llama_context *context;
      ~ResetCallback() { llama_set_abort_callback(context, nullptr, nullptr); }
    } reset{context_.get()};
    llama_set_abort_callback(
        context_.get(),
        [](void *data) { return static_cast<AbortState *>(data)->cancelled.load(); }, &state);
    ScoreDiagnostics local;
    return score_request(*this, request, manifest_, llama_n_ubatch(context_.get()), mode_,
                         cancelled, diagnostics_ ? *diagnostics_ : local);
  }

private:
  void clear() noexcept override {
    llama_synchronize(context_.get());
    llama_memory_clear(llama_get_memory(context_.get()), true);
  }
  void remove_branch() override {
    if (!llama_memory_seq_rm(llama_get_memory(context_.get()), 1, -1, -1))
      throw Error(503, "Unable to clear question sequence");
  }
  void copy_prefix() override {
    llama_memory_seq_cp(llama_get_memory(context_.get()), 0, 1, -1, -1);
  }
  VerdictRows decode(const Tokens &tokens, size_t position, int32_t sequence,
                     const std::vector<size_t> &slots) override {
    if (tokens.empty() || tokens.size() > llama_n_batch(context_.get()) || slots.size() > 26)
      throw Error(503, "Decode exceeds the configured batch or output capacity");
    struct Batch {
      llama_batch value;
      ~Batch() { llama_batch_free(value); }
    } batch{llama_batch_init(static_cast<int32_t>(tokens.size()), 0, 1)};
    batch.value.n_tokens = static_cast<int32_t>(tokens.size());
    for (size_t i = 0; i < tokens.size(); ++i) {
      batch.value.token[i] = tokens[i];
      batch.value.pos[i] = static_cast<llama_pos>(position + i);
      batch.value.n_seq_id[i] = 1;
      batch.value.seq_id[i][0] = sequence;
      batch.value.logits[i] = 0;
    }
    for (auto slot : slots)
      batch.value.logits[slot] = 1;
    const int result = llama_decode(context_.get(), batch.value);
    if (result == 2)
      throw Error(499, "Evaluation cancelled during decode");
    if (result != 0)
      throw Error(503, "Native decode failed: " + std::to_string(result));
    // Prefix decodes have no logits read to synchronize them before sequence copy.
    if (slots.empty())
      llama_synchronize(context_.get());
    VerdictRows rows;
    for (auto slot : slots) {
      const float *logits = llama_get_logits_ith(context_.get(), static_cast<int32_t>(slot));
      if (!logits)
        throw Error(503, "Missing requested verdict logits");
      rows.push_back(
          {static_cast<double>(logits[manifest_.yes]), static_cast<double>(logits[manifest_.no])});
    }
    return rows;
  }

  Manifest manifest_;
  ScoreMode mode_;
  ScoreDiagnostics *diagnostics_;
  std::unique_ptr<VerifiedModel> model_;
  std::unique_ptr<llama_context, decltype(&llama_free)> context_{nullptr, llama_free};
  const llama_vocab *vocab_ = nullptr;
};
} // namespace

std::unique_ptr<Backend> open_backend(const char *path, const Manifest &manifest) {
  return open_scoring_backend(path, manifest, ScoreMode::exact, nullptr, nullptr);
}

std::unique_ptr<Backend> open_scoring_backend(const char *path, const Manifest &manifest,
                                              ScoreMode mode, ScoreDiagnostics *diagnostics,
                                              Json *profile) {
  return std::make_unique<LlamaBackend>(path, manifest, mode, diagnostics, profile);
}
} // namespace edge_one
