#!/usr/bin/env python3
"""下载 DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic 的 GGUF 并校验 SHA256。

为什么不用 huggingface-cli：国内直连 huggingface.co 基本不通，而这个脚本
走分块 Range 请求，可以指定镜像与代理，断点续传，每块独立重试。

用法:
    python download-model.py                    # 只下主模型 Q4_K_M
    python download-model.py --with-mmproj      # 连视觉投影一起下
    python download-model.py --mirror hf-mirror --no-proxy
    python download-model.py --dest D:/models
"""
from __future__ import annotations

import argparse
import hashlib
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

REPO = "Sakura721/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic-GGUF"

FILES = {
    "model": {
        "name": "DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic-Q4_K_M.gguf",
        "size": 5_629_111_968,
        "sha256": "82a19e2f3c3834d6b9d1e17dacef27ebee5dd814bae3cce557f47ecca66dadab",
    },
    "mmproj": {
        "name": "mmproj-DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic-f16.gguf",
        "size": 918_167_360,
        "sha256": "f8d09a6d00ee3318c58f142a62a628346384a878d2f830f470a0483a49690a5e",
    },
}

MIRRORS = {
    "huggingface": "https://huggingface.co",
    "hf-mirror": "https://hf-mirror.com",
}

CHUNK = 8 * 1024 * 1024
CURL = "curl.exe" if sys.platform == "win32" else "curl"


def log(msg: str) -> None:
    print(msg, flush=True)


def fetch_chunk(url: str, dest: Path, start: int, end: int,
                proxy: str | None) -> int:
    """下载 [start, end] 到 dest，失败重试。返回字节数。"""
    want = end - start + 1
    if dest.exists() and dest.stat().st_size == want:
        return want

    for attempt in range(8):
        cmd = [CURL, "-sS", "-L", "--max-time", "180",
               "-r", f"{start}-{end}", "-o", str(dest), url]
        if proxy:
            cmd[3:3] = ["-x", proxy]
        else:
            cmd[3:3] = ["--noproxy", "*"]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode == 0 and dest.exists() and dest.stat().st_size == want:
            return want
        if dest.exists():
            dest.unlink()
        if attempt == 7:
            raise RuntimeError(
                f"分块 {start}-{end} 失败: {proc.stderr.strip()[:160]}")
    return 0


def download(entry: dict, dest_dir: Path, base: str, proxy: str | None) -> Path:
    name = entry["name"]
    expect = entry["size"]
    dest = dest_dir / name
    parts = Path(str(dest) + ".parts")

    if dest.exists() and dest.stat().st_size == expect:
        log(f"  已存在，跳过下载: {name}")
    else:
        parts.mkdir(parents=True, exist_ok=True)
        url = f"{base}/{REPO}/resolve/main/{name}"
        ranges, pos, i = [], 0, 0
        while pos < expect:
            end = min(pos + CHUNK, expect) - 1
            ranges.append((i, pos, end))
            pos, i = end + 1, i + 1

        log(f"  下载 {name}")
        log(f"    {len(ranges)} 块 x {CHUNK // 1024 // 1024} MiB, 8 线程")
        log(f"    源: {base}  代理: {proxy or '不使用'}")

        done = 0
        with ThreadPoolExecutor(max_workers=8) as pool:
            futs = [
                pool.submit(fetch_chunk, url, parts / f"{idx:05d}.part",
                            start, end, proxy)
                for idx, start, end in ranges
            ]
            for fut in as_completed(futs):
                fut.result()
                done += 1
                if done % 20 == 0 or done == len(ranges):
                    log(f"      {done}/{len(ranges)}")

        log("    合并中...")
        with open(dest, "wb") as out:
            for idx, _, _ in ranges:
                out.write((parts / f"{idx:05d}.part").read_bytes())
        for p in parts.glob("*.part"):
            p.unlink()
        parts.rmdir()

    log("  校验 SHA256 ...")
    h = hashlib.sha256()
    with open(dest, "rb") as fh:
        for blk in iter(lambda: fh.read(8 * 1024 * 1024), b""):
            h.update(blk)
    got = h.hexdigest()
    if got != entry["sha256"]:
        raise SystemExit(
            f"  校验失败!\n    期望 {entry['sha256']}\n    实际 {got}\n"
            f"    文件已保留在 {dest}，请检查网络后重试")
    log("  校验通过")
    return dest


def main() -> int:
    ap = argparse.ArgumentParser(description="下载 9B heretic 模型")
    ap.add_argument("--dest", default=str(Path.home() / "models" /
                                          "DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic"))
    ap.add_argument("--mirror", choices=list(MIRRORS), default="hf-mirror")
    ap.add_argument("--proxy", default=None,
                    help="例如 http://127.0.0.1:65532；不传则直连")
    ap.add_argument("--no-proxy", action="store_true", help="强制直连")
    ap.add_argument("--with-mmproj", action="store_true", help="同时下载视觉投影")
    args = ap.parse_args()

    proxy = None if args.no_proxy else args.proxy
    dest_dir = Path(args.dest).expanduser()
    dest_dir.mkdir(parents=True, exist_ok=True)
    base = MIRRORS[args.mirror]

    log(f"目标目录: {dest_dir}")
    targets = ["model"] + (["mmproj"] if args.with_mmproj else [])
    total = sum(FILES[k]["size"] for k in targets)
    log(f"共 {len(targets)} 个文件，约 {total / 1024**3:.2f} GiB\n")

    for key in targets:
        download(FILES[key], dest_dir, base, proxy)
        log("")

    log("全部完成。启动服务：")
    log(f"  MODEL_DIR={dest_dir} ./scripts/start-deepseek9b.sh start 32768")
    return 0


if __name__ == "__main__":
    sys.exit(main())
