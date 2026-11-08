#!/usr/bin/env python3
"""Upscale an H3 MP4 to 1K (1080p) or 2K (1440p) through local ComfyUI.

H3-Base renders natively around 768p and the official Regenerate-2K module is
hosted only. This runs a local post-process instead: Real-ESRGAN x2 per frame,
then an exact Lanczos resize to the target, keeping the original audio and fps.
"""

from __future__ import annotations

import argparse
import json
import shutil
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

DATA_ROOT = Path("/root/autodl-tmp/h3")
TARGET_SHORT_SIDE = {"1k": 1080, "2k": 1440}


def request_json(url: str, *, method: str = "GET", payload: dict | None = None) -> dict:
    body = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(
        url, data=body, method=method, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} from {url}: {detail}") from exc


def probe_size(path: Path) -> tuple[int, int]:
    import av  # installed with ComfyUI requirements

    with av.open(str(path)) as container:
        stream = container.streams.video[0]
        return stream.codec_context.width, stream.codec_context.height


def target_size(src_w: int, src_h: int, target: str) -> tuple[int, int]:
    if "x" in target:
        w, h = (int(v) for v in target.lower().split("x", 1))
    else:
        short = TARGET_SHORT_SIDE[target.lower()]
        scale = short / min(src_w, src_h)
        w, h = round(src_w * scale), round(src_h * scale)
    # Encoders need even sizes; multiples of 8 keep yuv420 macroblocks clean.
    w, h = max(8, round(w / 8) * 8), max(8, round(h / 8) * 8)
    return w, h


def build_prompt(video_name: str, model: str, width: int, height: int, prefix: str) -> dict:
    return {
        "1": {"class_type": "LoadVideo", "inputs": {"file": video_name}},
        "2": {"class_type": "GetVideoComponents", "inputs": {"video": ["1", 0]}},
        "3": {"class_type": "UpscaleModelLoader", "inputs": {"model_name": model}},
        "4": {
            "class_type": "ImageUpscaleWithModel",
            "inputs": {"upscale_model": ["3", 0], "image": ["2", 0]},
        },
        "5": {
            "class_type": "ImageScale",
            "inputs": {
                "image": ["4", 0],
                "upscale_method": "lanczos",
                "width": width,
                "height": height,
                "crop": "disabled",
            },
        },
        "6": {
            "class_type": "CreateVideo",
            "inputs": {"images": ["5", 0], "audio": ["2", 1], "fps": ["2", 2]},
        },
        "7": {
            "class_type": "SaveVideo",
            "inputs": {
                "video": ["6", 0],
                "filename_prefix": prefix,
                "format": "auto",
                "codec": "auto",
            },
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", help="Source MP4 (absolute, or relative to the H3 outputs dir)")
    parser.add_argument("--target", default="2k", help="1k, 2k, or WxH (default: 2k)")
    parser.add_argument("--model", default="RealESRGAN_x2plus.pth")
    parser.add_argument("--server", default="http://127.0.0.1:8188")
    parser.add_argument("--filename-prefix", help="Output prefix relative to the outputs dir")
    parser.add_argument("--timeout-seconds", type=int, default=3600)
    args = parser.parse_args()

    src = Path(args.video)
    if not src.is_absolute():
        src = DATA_ROOT / "outputs" / src
    if not src.is_file():
        raise SystemExit(f"source video not found: {src}")

    src_w, src_h = probe_size(src)
    width, height = target_size(src_w, src_h, args.target)
    print(f"source={src} {src_w}x{src_h} -> {width}x{height}")

    queue = request_json(f"{args.server}/queue")
    if queue.get("queue_running") or queue.get("queue_pending"):
        raise SystemExit("ComfyUI queue is busy; submit the upscale after the current task")

    # LoadVideo only accepts files in the ComfyUI input directory root.
    staged_name = f"h3up_{uuid.uuid4().hex[:8]}_{src.name}"
    staged = DATA_ROOT / "inputs" / staged_name
    shutil.copy2(src, staged)

    label = args.target.lower()
    prefix = args.filename_prefix or f"h3-upscaled/{src.stem}_{label}"
    prompt = build_prompt(staged_name, args.model, width, height, prefix)

    started = time.time()
    try:
        prompt_id = request_json(
            f"{args.server}/prompt", method="POST", payload={"prompt": prompt}
        )["prompt_id"]
        print("prompt_id=", prompt_id, flush=True)
        while time.time() < started + args.timeout_seconds:
            item = request_json(f"{args.server}/history/{prompt_id}").get(prompt_id)
            if item:
                status = item.get("status", {})
                if status.get("status_str") == "error":
                    print(json.dumps(status, indent=2))
                    return 1
                if status.get("completed"):
                    for node in item.get("outputs", {}).values():
                        for key in ("images", "videos", "gifs"):
                            for out in node.get(key, []):
                                path = DATA_ROOT / "outputs" / out.get("subfolder", "") / out["filename"]
                                print(f"output={path}")
                    print(f"duration_seconds={time.time() - started:.1f}")
                    return 0
            time.sleep(3)
        print(f"timed out after {args.timeout_seconds}s")
        return 2
    finally:
        staged.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
