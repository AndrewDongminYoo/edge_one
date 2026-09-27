#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface NativeBenchmark : NSObject
+ (nullable NSString *)runWithModelPath:(NSString *)modelPath
                           fixtureJSON:(NSString *)fixtureJSON
                         fixtureSHA256:(NSString *)fixtureSHA256
                           repetitions:(NSInteger)repetitions
                                 error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
