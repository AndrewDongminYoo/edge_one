#import "NativeBenchmark.h"
#include "../Benchmark.hpp"
#include <stdexcept>

@implementation NativeBenchmark
+ (nullable NSString *)runWithModelPath:(NSString *)modelPath
                           fixtureJSON:(NSString *)fixtureJSON
                         fixtureSHA256:(NSString *)fixtureSHA256
                           repetitions:(NSInteger)repetitions
                 sustainedMilliseconds:(NSInteger)sustainedMilliseconds
                                 error:(NSError **)error {
    try {
        if (repetitions < 1 || repetitions > 100 || sustainedMilliseconds < 0 || sustainedMilliseconds > 300000)
            throw std::runtime_error("invalid repetitions or sustained duration");
        const auto thermalState = []() -> int {
            return static_cast<int>([NSProcessInfo processInfo].thermalState);
        };
        const auto report = m0_benchmark(modelPath.UTF8String, fixtureJSON.UTF8String,
                                        fixtureSHA256.UTF8String, static_cast<int>(repetitions),
                                        static_cast<int>(sustainedMilliseconds), thermalState);
        return [NSString stringWithUTF8String:report.c_str()];
    } catch (const std::exception & exception) {
        if (error) *error = [NSError errorWithDomain:@"edge_one.m0" code:1
            userInfo:@{NSLocalizedDescriptionKey: @(exception.what())}];
        return nil;
    }
}
@end
