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

/// Replaces the live configuration JSON. The trusted engine thread re-reads it
/// through `bridge.configuration()` before every gateway request, so account
/// cookies/tokens added after startup take effect without restarting the engine.
+ (void)updateConfiguration:(NSString *)configuration
NS_SWIFT_NAME(updateConfiguration(_:));

+ (nullable NSString *)listeningURL;
+ (nullable NSString *)startupError;

@end

NS_ASSUME_NONNULL_END
