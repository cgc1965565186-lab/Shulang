#!/usr/bin/env python3
"""可复现的性能基准：合成目录树 → 两种枚举器各跑 N 次 → JSON 结果 → 清理。

用法: python3 Scripts/benchmark.py [--count 6000] [--runs 3]
"""
from pathlib import Path
import argparse
import hashlib
import json
import platform
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build" / "BENCHMARK.json"

# Each helper measures only its own CLI child; ru_maxrss is otherwise cumulative
# across all children of the benchmark process. On macOS it is reported in bytes.
MEASURE = """
import json, resource, subprocess, sys
result = subprocess.run(sys.argv[2:], capture_output=True, text=True, timeout=int(sys.argv[1]))
print(json.dumps({'code': result.returncode, 'stderr': result.stderr,
                  'stdout': result.stdout,
                  'rss': resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss}))
"""


def make_fixture(fixture: Path, count: int) -> None:
    per_dir = 200
    payload = b"x" * 512
    for index in range(count):
        bucket = index // per_dir
        folder = fixture / f"dir-{bucket:04d}"
        if not folder.exists():
            folder.mkdir()
        (folder / f"file-{index:06d}.bin").write_bytes(payload)
    # 附加：重复文件、稀疏文件、符号链接、隐藏文件
    (fixture / "duplicates").mkdir()
    same = b"identical" * 128
    (fixture / "duplicates" / "a.bin").write_bytes(same)
    (fixture / "duplicates" / "b.bin").write_bytes(same)
    (fixture / "old-installer.dmg").write_bytes(b"0" * 65536)
    (fixture / ".hidden").write_bytes(b"h" * 128)
    (fixture / "link-to-a").symlink_to(fixture / "duplicates" / "a.bin")


def run_once(cli: Path, fixture: Path, enumerator: str, timeout: int) -> tuple[float, int, str]:
    start = time.perf_counter()
    result = subprocess.run(
        [sys.executable, "-c", MEASURE, str(timeout), str(cli), "scan", str(fixture), "--hidden", "--enumerator", enumerator],
        capture_output=True, text=True, timeout=timeout + 5,
    )
    elapsed = time.perf_counter() - start
    if result.returncode != 0:
        raise RuntimeError(f"{enumerator} 扫描失败: {result.stderr.strip()}")
    measured = json.loads(result.stdout)
    if measured["code"] != 0:
        raise RuntimeError(f"{enumerator} 扫描失败: {measured['stderr'].strip()}")
    if "覆盖状态：complete" not in measured["stdout"]:
        raise RuntimeError(f"{enumerator} 扫描未完整覆盖夹具: {measured['stdout'].strip()}")
    return elapsed, measured["rss"], measured["stdout"].strip().splitlines()[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=6000)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=1800, help="每次扫描最长秒数")
    parser.add_argument("--cli", type=Path, default=ROOT / "build" / "shulang")
    parser.add_argument("--output", type=Path, default=OUT)
    args = parser.parse_args()
    if args.count < 1 or args.runs < 1 or args.timeout < 1:
        parser.error("count、runs 和 timeout 必须为正整数")
    cli = args.cli.resolve()
    if not cli.exists():
        print("缺少 build/shulang，请先运行 build-app.sh", file=sys.stderr)
        return 1
    cli_hash = hashlib.sha256(cli.read_bytes()).hexdigest()

    print(f"生成 {args.count} 个文件的合成目录树…")
    results = {}
    with tempfile.TemporaryDirectory(prefix="shulang-benchmark-") as temp_dir:
        fixture = Path(temp_dir)
        make_fixture(fixture, args.count)
        for enumerator in ("foundation", "bulk"):
            runs = [run_once(cli, fixture, enumerator, args.timeout) for _ in range(args.runs)]
            for _, _, summary in runs:
                files = re.search(r"文件 (\d+) 项", summary)
                if not files or int(files.group(1)) != args.count + 4:
                    raise RuntimeError(f"{enumerator} 扫描文件数与夹具不符: {summary}")
            times = [elapsed for elapsed, _, _ in runs]
            memory = [size for _, size, _ in runs]
            times.sort()
            results[enumerator] = {
                "runs_seconds": [round(t, 4) for t in times],
                "p50_seconds": round(times[len(times) // 2], 4),
                "min_seconds": round(times[0], 4),
                "max_seconds": round(times[-1], 4),
                "peak_rss_bytes": max(memory) if memory else None,
                "scan_summary": runs[0][2],
            }
            print(f"  {enumerator}: P50 {results[enumerator]['p50_seconds']}s")

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "machine": platform.machine(),
        "macos": platform.mac_ver()[0],
        "python": platform.python_version(),
        "fixture_files": args.count,
        "runs_per_enumerator": args.runs,
        "enumerators": results,
        "cli_path": str(cli),
        "cli_sha256": cli_hash,
        "note": "合成 fixture 使用独立临时目录并在测试后清理；耗时含进程启动，内存为进程峰值 RSS，不含 GUI。",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"基准结果：{args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
