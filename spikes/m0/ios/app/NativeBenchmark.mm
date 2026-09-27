#import "NativeBenchmark.h"
#include "../Benchmark.hpp"
#include <stdexcept>

@implementation NativeBenchmark
+ (nullable NSString *)runWithModelPath:(NSString *)modelPath
                           fixtureJSON:(NSString *)fixtureJSON
                         fixtureSHA256:(NSString *)fixtureSHA256
                           repetitions:(NSInteger)repetitions
                                 error:(NSError **)error {
    try {
        if (repetitions < 1 || repetitions > 100)
            throw std::runtime_error("repetitions must be between 1 and 100");
        const auto report = m0_benchmark(modelPath.UTF8String, fixtureJSON.UTF8String,
                                        fixtureSHA256.UTF8String, static_cast<int>(repetitions));
        return [NSString stringWithUTF8String:report.c_str()];
    } catch (const std::exception & exception) {
        if (error) *error = [NSError errorWithDomain:@"edge_one.m0" code:1
            userInfo:@{NSLocalizedDescriptionKey: @(exception.what())}];
        return nil;
    }
}
@end
