#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 进程内嵌的 CPython，只用来跑猫源插件。
///
/// 它是"可选件"：没有链接 Python 框架的构建会返回 0，调用方据此把 Python 源
/// 标成"当前包不支持"，而不是崩掉。
@interface YueduPythonRuntime : NSObject

/// 启动内嵌解释器并拉起本地服务，返回监听端口；0 表示当前包没有 Python 运行时。
/// - root: 放 PythonSpider 的目录（.app 内）
/// - cache: 可写目录
/// - scan: 要扫描 .py 的目录，可为空
+ (NSInteger)startWithRoot:(NSString *)root
                     cache:(NSString *)cache
                      scan:(nullable NSString *)scan
NS_SWIFT_NAME(start(root:cache:scan:));

/// 最近一次启动失败的原因，给界面提示用。
+ (nullable NSString *)startupError;

@end

NS_ASSUME_NONNULL_END
