#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A single in-process Node.js engine for CatVod spider bundles.
/// Provider code runs in V8 workers; only the trusted engine thread may read configuration.
@interface YueduNodeRuntime : NSObject

+ (void)startWithScript:(NSString *)script
        assetsDirectory:(NSString *)assetsDirectory
       runtimeDirectory:(NSString *)directory
          configuration:(NSString *)configuration
NS_SWIFT_NAME(start(script:assetsDirectory:runtimeDirectory:configuration:));

+ (nullable NSString *)listeningURL;
+ (nullable NSString *)startupError;

@end

NS_ASSUME_NONNULL_END
