#!/usr/bin/env bash
# 准备 Python 运行时（构建前跑一次，幂等）。
#
# 产物两样，都落在 Packages/PythonRuntime/Vendor/ 下，不进 git：
#   Python.xcframework  —— beeware/Python-Apple-support 的官方 iOS 预编译包，含真机与模拟器 slice；
#   python/             —— PYTHONHOME：标准库 + lib-dynload（_ssl/_hashlib/zlib/sqlite3 都在里面）。
#
# 为什么要拆成这两样：xcframework 里的 Python.framework 只有解释器本体，标准库在包的另一处。
# 打包时要把 python/ 拷进 .app 根目录，PYTHONHOME 指过去，否则 import os 都会失败。
set -euo pipefail

tag="${PYTHON_APPLE_TAG:-3.13-b18}"
python_version="${PYTHON_VERSION:-3.13}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vendor="$root/Packages/PythonRuntime/Vendor"
archive="$vendor/python-support.tar.gz"
url="https://github.com/beeware/Python-Apple-support/releases/download/${tag}/Python-${python_version}-iOS-support.${tag##*-}.tar.gz"

mkdir -p "$vendor"

if [[ -d "$vendor/Python.xcframework" && -d "$vendor/python/lib/python${python_version}" ]]; then
  echo "Python 运行时已就绪：$vendor"
  exit 0
fi

if [[ -n "${PYTHON_SUPPORT_ARCHIVE:-}" ]]; then
  echo "使用本地包：$PYTHON_SUPPORT_ARCHIVE"
  cp "$PYTHON_SUPPORT_ARCHIVE" "$archive"
else
  echo "下载 $url"
  curl -fL --retry 3 --retry-delay 2 -o "$archive" "$url"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tar xzf "$archive" -C "$work"

rm -rf "$vendor/Python.xcframework" "$vendor/python"
mv "$work/Python.xcframework" "$vendor/Python.xcframework"

# PYTHONHOME 布局：lib/python3.13（纯 Python 标准库）+ lib/python3.13/lib-dynload（C 扩展）。
mkdir -p "$vendor/python/lib"
cp -R "$vendor/Python.xcframework/lib/python${python_version}" "$vendor/python/lib/python${python_version}"
mkdir -p "$vendor/python/lib/python${python_version}/lib-dynload"
cp -R "$vendor/Python.xcframework/ios-arm64/lib-arm64/python${python_version}/lib-dynload/." \
      "$vendor/python/lib/python${python_version}/lib-dynload/"

# 测试套件和文档占了标准库一半体积，运行时用不到。
rm -rf "$vendor/python/lib/python${python_version}/test" \
       "$vendor/python/lib/python${python_version}/idlelib" \
       "$vendor/python/lib/python${python_version}/tkinter" \
       "$vendor/python/lib/python${python_version}/ensurepip" \
       "$vendor/python/lib/python${python_version}/config-${python_version}"* \
       "$vendor/python/lib/python${python_version}/site-packages"
# 编译扩展用的头文件和交叉编译工具链也不需要跟着 App 走。
rm -rf "$vendor/Python.xcframework/ios-arm64/include" \
       "$vendor/Python.xcframework/ios-arm64/bin" \
       "$vendor/Python.xcframework/ios-arm64/lib" \
       "$vendor/Python.xcframework/ios-arm64_x86_64-simulator/include" \
       "$vendor/Python.xcframework/ios-arm64_x86_64-simulator/bin"

rm -f "$archive"
echo "完成：$(du -sh "$vendor/Python.xcframework" | cut -f1) 框架 + $(du -sh "$vendor/python" | cut -f1) 标准库"
