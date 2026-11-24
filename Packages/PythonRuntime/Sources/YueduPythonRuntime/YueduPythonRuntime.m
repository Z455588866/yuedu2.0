#import "YueduPythonRuntime.h"

#if __has_include(<Python/Python.h>)
#define YUEDU_HAS_PYTHON 1
#include <Python/Python.h>
#else
#define YUEDU_HAS_PYTHON 0
#endif

static NSString *startupErrorText;

#if YUEDU_HAS_PYTHON
/// 服务对象要一直活到进程结束，否则 Python 侧那个 ThreadingHTTPServer 会被回收。
static PyObject *bridgeService;
#endif

@implementation YueduPythonRuntime

+ (NSString *)startupError {
    @synchronized (self) { return startupErrorText; }
}

+ (void)record:(NSString *)message {
    @synchronized (self) { startupErrorText = message; }
}

+ (NSString *)literal:(NSDictionary<NSString *, NSString *> *)values {
    NSMutableArray *parts = [NSMutableArray array];
    [values enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        NSString *escaped = [value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
        [parts addObject:[NSString stringWithFormat:@"'%@': '%@'", key, escaped]];
    }];
    return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
}

+ (NSInteger)startWithRoot:(NSString *)root cache:(NSString *)cache scan:(NSString *)scan {
#if YUEDU_HAS_PYTHON
    @synchronized (self) {
        if (bridgeService != NULL) {
            // 已经起过了：重复调用返回同一个端口，别把第二个解释器拉起来。
            PyGILState_STATE state = PyGILState_Ensure();
            PyObject *port = PyObject_GetAttrString(bridgeService, "port");
            long value = port ? PyLong_AsLong(port) : 0;
            Py_XDECREF(port);
            PyGILState_Release(state);
            return (NSInteger)value;
        }
    }
    NSString *home = [root stringByAppendingPathComponent:@"Python"];
    NSString *spiders = [root stringByAppendingPathComponent:@"PythonSpider"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:spiders]) {
        [self record:@"安装包里没有 Python 源组件"];
        return 0;
    }

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    // 手机上没有终端，信号交给 App 自己管；也不读环境变量，避免被外部影响。
    config.install_signal_handlers = 0;
    config.use_environment = 0;
    PyConfig_SetBytesString(&config, &config.home, home.fileSystemRepresentation);
    PyConfig_SetBytesString(&config, &config.program_name, "yuedu-python");
    PyStatus status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        [self record:[NSString stringWithFormat:@"Python 初始化失败：%s",
                      status.err_msg ?: "unknown"]];
        return 0;
    }

    // 参数用 JSON 传进去再解析，省得在 C 字符串里跟路径中的引号较劲。
    NSString *script = [NSString stringWithFormat:
        @"import sys, json\n"
         "paths = json.loads(%@)\n"
         "sys.path.insert(0, paths['spiders'])\n"
         "sys.path.append(paths['spiders'] + '/vendor')\n"
         "sys.path.append(paths['spiders'] + '/shims')\n"
         "import bridge\n"
         "service = bridge.start(paths['cache'], [], 0, paths['scan'] or None)\n"
         "port = service.port\n",
        [self literal:@{
            @"spiders": spiders,
            @"cache": cache,
            @"scan": scan ?: @""
        }]];

    PyObject *globals = PyDict_New();
    PyDict_SetItemString(globals, "__builtins__", PyEval_GetBuiltins());
    PyObject *outcome = PyRun_String(script.UTF8String, Py_file_input, globals, globals);
    if (outcome == NULL) {
        PyErr_Print();
        Py_DECREF(globals);
        [self record:@"Python 源服务启动失败（详见 App 日志）"];
        return 0;
    }
    Py_DECREF(outcome);

    PyObject *port = PyDict_GetItemString(globals, @"port");
    long value = port ? PyLong_AsLong(port) : 0;
    PyObject *service = PyDict_GetItemString(globals, @"service");
    if (service) {
        Py_INCREF(service);
        bridgeService = service;
    }
    Py_DECREF(globals);

    // 之后所有 Python 代码都在服务自己的线程里跑，主线程不再持有 GIL。
    PyEval_SaveThread();
    if (value <= 0) {
        [self record:@"Python 源服务没有起来"];
        return 0;
    }
    return (NSInteger)value;
#else
    [self record:@"这个安装包没有内置 Python（构建时没有链接 Python 框架）"];
    return 0;
#endif
}

@end
