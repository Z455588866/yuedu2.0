#!/usr/bin/env python3
"""批量跑 Python 猫源的 homeContent，出一张"哪些源真的能用"的表。

    python3 tools/pyspider-selftest.py /path/to/py-sources
    python3 tools/pyspider-selftest.py /path/to/py-sources --json report.json

为什么要它：83 个源里必然有一部分站点已经死了、一部分依赖本机没有的库。靠肉眼点不动，
而"改了宿主之后到底好了没有"必须有可重复的数字，否则又变成凭感觉。
"""
import argparse
import concurrent.futures
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Packages", "PythonRuntime", "PythonSpider"))

import bridge as pybridge  # noqa: E402


def collect(directory):
    sources = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".py"):
            continue
        path = os.path.join(directory, name)
        stem = os.path.splitext(name)[0]
        key = "".join(ch if ch.isalnum() else "-" for ch in stem)[:60].strip("-") or "src"
        sources.append({"key": key, "name": stem, "api": path, "ext": ""})
    return sources


def probe(bridge, source, timeout):
    """直接调 Session，不经过 HTTP：省一层超时和端口，测的是同一份逻辑。"""
    started = time.time()
    try:
        session = bridge.registry.session(bridge.registry.token(source["key"]))
        result = session.call("home", {})
        classes = result.get("class") or []
        videos = result.get("list") or []
        return {
            "key": source["key"],
            "name": source["name"],
            "ok": True,
            "classes": len(classes),
            "videos": len(videos),
            "seconds": round(time.time() - started, 1),
            "sample": (classes[0].get("type_name") if classes else "") or "",
        }
    except Exception as error:  # noqa: BLE001
        detail = pybridge.pyhost.envelope(error)
        return {
            "key": source["key"],
            "name": source["name"],
            "ok": False,
            "seconds": round(time.time() - started, 1),
            "code": detail.get("errorCode"),
            "error": detail.get("error")[:160],
        }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory")
    parser.add_argument("--json")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--cache", default="/tmp/pyspider-selftest")
    options = parser.parse_args()

    sources = collect(options.directory)
    if options.limit:
        sources = sources[: options.limit]
    if not sources:
        print("没有找到 .py 文件")
        return 1
    os.makedirs(options.cache, exist_ok=True)
    bridge = pybridge.Bridge(options.cache, sources)
    print("%d 个源，%d 并发\n" % (len(sources), options.workers))

    rows = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=options.workers) as pool:
        futures = {pool.submit(probe, bridge, s, 40): s for s in sources}
        for future in concurrent.futures.as_completed(futures):
            row = future.result()
            rows.append(row)
            mark = "OK  " if row["ok"] else "FAIL"
            if row["ok"]:
                print("%s %-28s 分类 %-3d 推荐 %-3d %5.1fs %s"
                      % (mark, row["name"][:28], row["classes"], row["videos"], row["seconds"], row["sample"]))
            else:
                print("%s %-28s %5.1fs [%s] %s"
                      % (mark, row["name"][:28], row["seconds"], row.get("code"), row.get("error")))

    rows.sort(key=lambda r: (not r["ok"], -r.get("classes", 0)))
    good = [r for r in rows if r["ok"] and (r.get("classes") or r.get("videos"))]
    empty = [r for r in rows if r["ok"] and not (r.get("classes") or r.get("videos"))]
    bad = [r for r in rows if not r["ok"]]
    print("\n可用 %d / 空结果 %d / 失败 %d  (共 %d)" % (len(good), len(empty), len(bad), len(rows)))
    if bad:
        from collections import Counter
        print("失败原因：", dict(Counter(r.get("code") for r in bad)))
    if options.json:
        with open(options.json, "w", encoding="utf-8") as stream:
            json.dump(rows, stream, ensure_ascii=False, indent=2)
        print("明细写入", options.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
