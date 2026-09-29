#import <UIKit/UIKit.h>
#include <CommonCrypto/CommonDigest.h>
#include "fixture_tokens.hpp"
#include "ggml-backend.h"
#include "llama-model.h"
#include <cstring>
#include <fstream>
#include <iomanip>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <vector>

static void verify_model_hash(const char * model_path) {
    std::ifstream file(model_path, std::ios::binary);
    if (!file) throw std::runtime_error("model not found");
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    std::vector<char> buffer(1024 * 1024);
    while (file.read(buffer.data(), buffer.size()) || file.gcount())
        CC_SHA256_Update(&context, buffer.data(), static_cast<CC_LONG>(file.gcount()));
    if (!file.eof()) throw std::runtime_error("model read failed");
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    std::ostringstream actual;
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i)
        actual << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(digest[i]);
    if (actual.str() != m0_model_hash) throw std::runtime_error("model hash mismatch");
}

static void write_repro_status(NSString * status) {
    NSURL * directory = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [status writeToURL:[directory URLByAppendingPathComponent:@"native-repro-status.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

struct NativeBackend {
    NativeBackend() { llama_backend_init(); }
    ~NativeBackend() { llama_backend_free(); }
};

static size_t metal_weight_bytes(const llama_model * model) {
    size_t total = 0;
    for (const auto & [buffer_type, bytes] : model->memory_breakdown()) {
        ggml_backend_dev_t device = ggml_backend_buft_get_device(buffer_type);
        if (!device) continue;
        const char * backend = ggml_backend_reg_name(ggml_backend_dev_backend_reg(device));
        const auto type = ggml_backend_dev_type(device);
        if (backend && std::strcmp(backend, "MTL") == 0 &&
            (type == GGML_BACKEND_DEVICE_TYPE_GPU || type == GGML_BACKEND_DEVICE_TYPE_IGPU))
            total += bytes;
    }
    return total;
}

// Direct llama.cpp reproduction: no Scorer, Swift, renderer or JSON path.
static void decode_once(const char * model_path, bool gpu, bool diagnostic, std::ostream & out, std::ostream & single) {
    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = gpu ? 999 : 0;
    std::unique_ptr<llama_model, decltype(&llama_model_free)> model(
        llama_model_load_from_file(model_path, mp), llama_model_free);
    if (!model) throw std::runtime_error("model load failed");
    if (gpu) {
        const size_t bytes = metal_weight_bytes(model.get());
        if (bytes == 0) throw std::runtime_error("Metal weight offload absent");
        out << "metal_offload MTL " << bytes << '\n';
    }
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = cp.n_batch = 2048;
    cp.n_ubatch = 1024;
    cp.n_seq_max = 2;
    cp.n_outputs_max = 16;
    cp.n_threads = cp.n_threads_batch = 4;
    cp.kv_unified = true;
    cp.no_perf = true;
    cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
    cp.offload_kqv = cp.op_offload = gpu;
    std::unique_ptr<llama_context, decltype(&llama_free)> ctx(
        llama_init_from_model(model.get(), cp), llama_free);
    if (!ctx) throw std::runtime_error("context init failed");
    const int count = sizeof(m0_tokens) / sizeof(m0_tokens[0]);
    const auto run_batch = [&](int single_slot) {
        llama_memory_clear(llama_get_memory(ctx.get()), true);
        llama_memory_clear(llama_get_memory(ctx.get()), true);
        llama_batch batch = llama_batch_init(count, 0, 1);
        batch.n_tokens = count;
        for (int i = 0; i < count; ++i) {
            batch.token[i] = m0_tokens[i];
            batch.pos[i] = i;
            batch.n_seq_id[i] = 1;
            batch.seq_id[i][0] = 0;
            batch.logits[i] = 0;
        }
        for (auto slot : m0_slots)
            if (single_slot < 0 || single_slot == slot) batch.logits[slot] = 1;
        const int rc = llama_decode(ctx.get(), batch);
        llama_batch_free(batch);
        if (rc != 0) throw std::runtime_error("llama_decode failed");
        llama_synchronize(ctx.get());
    };
    run_batch(-1);
    for (size_t i = 0; i < sizeof(m0_slots) / sizeof(m0_slots[0]); ++i) {
        const float * logits = llama_get_logits_ith(ctx.get(), m0_slots[i]);
        if (!logits) throw std::runtime_error("missing logits");
        out << (gpu ? "metal" : "cpu") << ' ' << i;
        for (auto row : m0_rows) out << ' ' << logits[row];
        out << '\n';
    }
    if (diagnostic) {
        for (size_t i = 0; i < sizeof(m0_slots) / sizeof(m0_slots[0]); ++i) {
            run_batch(m0_slots[i]);
            const float * logits = llama_get_logits_ith(ctx.get(), m0_slots[i]);
            if (!logits) throw std::runtime_error("missing single-slot logits");
            single << (gpu ? "single_metal" : "single_cpu") << ' ' << i << ' ' << m0_slots[i];
            for (auto row : m0_rows) single << ' ' << logits[row];
            single << '\n';
        }
    }
}

@interface NativeReproScene : UIResponder <UIWindowSceneDelegate>
@property(strong, nonatomic) UIWindow * window;
@end

@implementation NativeReproScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController * controller = [UIViewController new];
    UILabel * label = [[UILabel alloc] initWithFrame:self.window.bounds];
    label.textAlignment = NSTextAlignmentCenter;
    label.text = @"Running direct llama.cpp repro";
    controller.view = label;
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString * status;
        write_repro_status(@"started");
        try {
            std::ostringstream out;
            std::ostringstream single;
            out << std::setprecision(17) << "fixture_sha256 " << m0_fixture_hash << '\n';
            single << std::setprecision(17);
            const bool invalidModel = [NSProcessInfo.processInfo.arguments containsObject:@"--invalid-model"];
            const bool diagnostic = [NSProcessInfo.processInfo.arguments containsObject:@"--single-slot-diagnostic"];
            NSString * modelPath = invalidModel
                ? [NSBundle.mainBundle pathForResource:@"fixture" ofType:@"json"]
                : [NSBundle.mainBundle pathForResource:@"model" ofType:@"gguf"];
            if (!modelPath) throw std::runtime_error("model resource missing");
            verify_model_hash(modelPath.UTF8String);
            write_repro_status(@"model_verified");
            static NativeBackend backend;
            decode_once(modelPath.UTF8String, false, diagnostic, out, single);
            write_repro_status(@"cpu_complete");
            decode_once(modelPath.UTF8String, true, diagnostic, out, single);
            write_repro_status(@"metal_complete");
            NSURL * directory = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
            NSError * error = nil;
            if (diagnostic) {
                NSString * singleResult = [NSString stringWithUTF8String:single.str().c_str()];
                if (![singleResult writeToURL:[directory URLByAppendingPathComponent:@"native-repro-single.txt"] atomically:YES encoding:NSUTF8StringEncoding error:&error])
                    throw std::runtime_error("single-slot output write failed");
            }
            NSString * result = [NSString stringWithUTF8String:out.str().c_str()];
            if (![result writeToURL:[directory URLByAppendingPathComponent:@"native-repro.txt"] atomically:YES encoding:NSUTF8StringEncoding error:&error])
                throw std::runtime_error("repro output write failed");
            status = @"Native repro complete";
        } catch (const std::exception & error) {
            status = [NSString stringWithFormat:@"Repro failed: %s", error.what()];
        }
        write_repro_status(status);
        dispatch_async(dispatch_get_main_queue(), ^{ label.text = status; });
    });
}
@end

@interface NativeReproApp : UIResponder <UIApplicationDelegate>
@end

@implementation NativeReproApp
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration * configuration = [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:session.role];
    configuration.delegateClass = NativeReproScene.class;
    return configuration;
}
@end

int main(int argc, char ** argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(NativeReproApp.class)); }
}
