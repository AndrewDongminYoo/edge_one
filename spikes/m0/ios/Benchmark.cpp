#include "Benchmark.hpp"
#include <CommonCrypto/CommonDigest.h>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>

// Include the verified reference implementation without using its process/stdio CLI.
// Source integrity is checked by build.py before compilation.
#define main m0_unused_reference_cli
#include "jev_score.cpp"
#undef main

namespace {
std::mutex benchmark_mutex;

std::string hex_digest(const unsigned char * bytes) {
    std::ostringstream out;
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i)
        out << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(bytes[i]);
    return out.str();
}

std::string model_hash(const std::string & path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) throw std::runtime_error("model not found");
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    std::vector<char> buffer(1024 * 1024);
    while (file.read(buffer.data(), buffer.size()) || file.gcount())
        CC_SHA256_Update(&context, buffer.data(), static_cast<CC_LONG>(file.gcount()));
    if (!file.eof()) throw std::runtime_error("model read failed");
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    return hex_digest(digest);
}

json decision(const json & native, const json & fixture) {
    const auto names = fixture.at("option_names").get<std::vector<std::string>>();
    const auto & scored = native.at("results").at(0);
    const auto & rows = scored.at("scores");
    if (!scored.at("finite").get<bool>() || rows.size() != names.size())
        throw std::runtime_error("invalid native scores");
    const double temperature = fixture.at("temperature").get<double>();
    std::vector<double> logits;
    for (const auto & row : rows) {
        if (row.size() != 2) throw std::runtime_error("invalid native score row");
        const double value = (row.at(0).get<double>() - row.at(1).get<double>()) / temperature;
        if (!std::isfinite(value)) throw std::runtime_error("nonfinite verdict score");
        logits.push_back(value);
    }
    const double maximum = *std::max_element(logits.begin(), logits.end());
    double total = 0;
    for (auto & value : logits) { value = std::exp(value - maximum); total += value; }
    json probabilities = json::object();
    size_t best = 0;
    for (size_t i = 0; i < names.size(); ++i) {
        probabilities[names[i]] = logits[i] / total;
        if (logits[i] > logits[best]) best = i;
    }
    return {{"answer", names[best]}, {"probabilities", probabilities}};
}

struct Backend {
    Backend() { llama_backend_init(); }
    ~Backend() { llama_backend_free(); }
};
} // namespace

std::string m0_benchmark(const std::string & model_path, const std::string & fixture_json,
                         const std::string & fixture_sha256, int repetitions) {
    std::lock_guard<std::mutex> lock(benchmark_mutex);
    if (repetitions < 1 || repetitions > 100 || fixture_json.size() > 1024 * 1024)
        throw std::runtime_error("invalid repetitions or fixture size");
    unsigned char fixture_digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(fixture_json.data(), static_cast<CC_LONG>(fixture_json.size()), fixture_digest);
    if (hex_digest(fixture_digest) != fixture_sha256)
        throw std::runtime_error("fixture SHA-256 mismatch");
    const json fixture = json::parse(fixture_json);
    const json & request = fixture.at("native_request");
    const auto names = fixture.at("option_names").get<std::vector<std::string>>();
    const double temperature = fixture.at("temperature").get<double>();
    if (names.empty() || !std::isfinite(temperature) || temperature <= 0 ||
        request.at("questions").size() != 1 || request.at("mode") != "fused" ||
        request.at("keep_prefix") != false || request.at("share_prefix") != true)
        throw std::runtime_error("expected one fused Choice request");
    const auto integrity_start = clk::now();
    const char * cpu_only = std::getenv("M0_CPU_ONLY");
    const int gpu_layers = cpu_only && std::string(cpu_only) == "1" ? 0 : 999;
    const std::string actual_hash = model_hash(model_path);
    if (actual_hash != fixture.at("model_sha256").get<std::string>())
        throw std::runtime_error("model SHA-256 mismatch");
    json metadata = {
        {"pins", fixture.at("pins")}, {"model_sha256", actual_hash}, {"model_hash_verified", true},
        {"fixture_sha256", hex_digest(fixture_digest)}, {"integrity_ms", ms_since(integrity_start)},
        {"repetitions", repetitions}, {"threads", 4}, {"n_gpu_layers", gpu_layers}, {"flash_attn", "auto"},
        {"offload_kqv", gpu_layers != 0}, {"op_offload", gpu_layers != 0},
        {"metal_fusion_disable_requested", std::getenv("GGML_METAL_FUSION_DISABLE") != nullptr},
        {"metal_shared_buffers_disable_requested", std::getenv("GGML_METAL_SHARED_BUFFERS_DISABLE") != nullptr},
        {"compiler", __VERSION__},
        {"timing_scope", "pretokenized native scoring including internal memory resets and verdict softmax"},
        {"device", {{"platform", "host"}, {"simulator", false}, {"hardware", "unknown"}, {"os", "unknown"}}}
    };
    llama_log_set([](enum ggml_log_level level, const char * text, void *) {
        if (level >= GGML_LOG_LEVEL_WARN) fputs(text, stderr);
    }, nullptr);
    // The backend outlives every model/context and is released at process exit.
    static Backend backend;
    const auto load_start = clk::now();
    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = gpu_layers;
    std::unique_ptr<llama_model, decltype(&llama_model_free)> model(
        llama_model_load_from_file(model_path.c_str(), mp), llama_model_free);
    if (!model) throw std::runtime_error("model load failed");
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = 2048;
    cp.n_batch = 2048;
    cp.n_ubatch = 1024;
    cp.n_seq_max = 2;
    cp.n_outputs_max = 16;
    cp.n_threads = cp.n_threads_batch = 4;
    cp.kv_unified = true;
    cp.no_perf = true;
    cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
    cp.offload_kqv = gpu_layers != 0;
    cp.op_offload = gpu_layers != 0;
    std::unique_ptr<llama_context, decltype(&llama_free)> context(
        llama_init_from_model(model.get(), cp), llama_free);
    if (!context) throw std::runtime_error("context init failed");
    Scorer scorer;
    scorer.model = model.get();
    scorer.ctx = context.get();
    scorer.n_ctx = static_cast<int>(llama_n_ctx(context.get()));
    scorer.n_batch = static_cast<int>(llama_n_batch(context.get()));
    scorer.n_seq_max = static_cast<int>(llama_n_seq_max(context.get()));
    scorer.n_outputs_max = cp.n_outputs_max;
    scorer.n_vocab = llama_vocab_n_tokens(llama_model_get_vocab(model.get()));
    char description[256];
    llama_model_desc(model.get(), description, sizeof(description));
    json report = {
        {"schema_version", 1}, {"metadata", metadata},
        {"ready", {{"n_ctx", scorer.n_ctx}, {"n_batch", scorer.n_batch}, {"n_ubatch", cp.n_ubatch},
                   {"n_seq_max", scorer.n_seq_max}, {"n_outputs_max", scorer.n_outputs_max},
                   {"load_ms", ms_since(load_start)}, {"desc", description},
                   {"system_info", llama_print_system_info()}}},
        {"records", json::array()}
    };
    for (int sample = 0; sample <= repetitions; ++sample) {
        scorer.clear();
        const auto start = clk::now();
        json response = scorer.handle(request);
        json result = decision(response, fixture);
        const double duration = ms_since(start);
        report["records"].push_back({
            {"sample", sample}, {"phase", sample == 0 ? "first" : "warm"},
            {"duration_ms", duration}, {"memory_reset", true},
            {"native_response", response}, {"result", result}
        });
    }
    return report.dump();
}
