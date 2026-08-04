#!/usr/bin/env python3
"""Submit and monitor a small MiniMax H3 T2VA smoke test to local ComfyUI."""

from __future__ import annotations

import argparse
import json
import time
import urllib.error
import urllib.request
from pathlib import Path


def request_json(url: str, *, method: str = "GET", payload: dict | None = None) -> dict:
    body = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(
        url,
        data=body,
        method=method,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} from {url}: {detail}") from exc


def build_prompt(args: argparse.Namespace) -> dict:
    return {
        "1": {
            "class_type": "UNETLoader",
            "inputs": {
                "unet_name": "minimax_h3_fl2va_pruned_int8_convrot.safetensors",
                "weight_dtype": "default",
            },
        },
        "2": {
            "class_type": "CLIPLoader",
            "inputs": {
                "clip_name": "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
                "type": "minimax",
                "device": "default",
            },
        },
        "3": {
            "class_type": "VAELoader",
            "inputs": {"vae_name": "minimax_h3_video_vae_fp16.safetensors"},
        },
        "4": {
            "class_type": "VAELoader",
            "inputs": {"vae_name": "minimax_h3_audio_vae_fp32.safetensors"},
        },
        "5": {
            "class_type": "MiniMaxH3ImageToVideo",
            "inputs": {
                "clip": ["2", 0],
                "vae": ["3", 0],
                "prompt": args.prompt,
                "width": args.width,
                "height": args.height,
                "length": args.length,
            },
        },
        "6": {
            "class_type": "BasicScheduler",
            "inputs": {
                "model": ["1", 0],
                "scheduler": "simple",
                "steps": args.steps,
                "denoise": 1.0,
            },
        },
        "7": {
            "class_type": "RandomNoise",
            "inputs": {"noise_seed": args.seed},
        },
        "8": {
            "class_type": "KSamplerSelect",
            "inputs": {"sampler_name": "res_multistep"},
        },
        "9": {
            "class_type": "BasicGuider",
            "inputs": {"model": ["1", 0], "conditioning": ["5", 0]},
        },
        "10": {
            "class_type": "SamplerCustomAdvanced",
            "inputs": {
                "noise": ["7", 0],
                "guider": ["9", 0],
                "sampler": ["8", 0],
                "sigmas": ["6", 0],
                "latent_image": ["5", 1],
            },
        },
        "11": {
            "class_type": "VAEDecode",
            "inputs": {"samples": ["10", 0], "vae": ["3", 0]},
        },
        "12": {
            "class_type": "VAEDecodeAudio",
            "inputs": {"samples": ["10", 0], "vae": ["4", 0]},
        },
        "13": {
            "class_type": "CreateVideo",
            "inputs": {
                "images": ["11", 0],
                "audio": ["12", 0],
                "fps": 24.0,
                "bit_depth": 8,
            },
        },
        "14": {
            "class_type": "SaveVideo",
            "inputs": {
                "video": ["13", 0],
                "filename_prefix": args.filename_prefix,
                "format": "auto",
                # DynamicCombo inputs are submitted to ComfyUI's execution API
                # as the selected option key. The nested dict shown by the V3
                # schema describes that option; passing it as the live value
                # makes the normalizer drop the input entirely.
                "codec": "auto",
            },
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", default="http://127.0.0.1:8188")
    parser.add_argument("--width", type=int, default=608)
    parser.add_argument("--height", type=int, default=352)
    parser.add_argument("--length", type=int, default=56, help="17k+5 aligned frames")
    parser.add_argument("--steps", type=int, default=5)
    parser.add_argument("--seed", type=int, default=20260803)
    parser.add_argument("--poll-seconds", type=float, default=5.0)
    parser.add_argument("--timeout-seconds", type=int, default=7200)
    parser.add_argument(
        "--filename-prefix",
        default="h3-smoke/minimax_h3",
        help="Path prefix relative to ComfyUI's configured output directory",
    )
    parser.add_argument(
        "--prompt",
        default=(
            "Cinematic live-action shot of a small red paper airplane gliding over a quiet "
            "sunlit lake at dawn. The camera tracks smoothly beside it as mist drifts over "
            "the water. Natural stereo ambience: gentle wind, distant birds, and soft water "
            "ripples. No text, subtitles, logos, or watermark."
        ),
    )
    parser.add_argument(
        "--prompt-file",
        help="UTF-8 JSON file containing a top-level prompt string; overrides --prompt",
    )
    parser.add_argument(
        "--record",
        default="/root/autodl-tmp/h3/logs/h3-smoke-request.json",
    )
    parser.add_argument(
        "--result-record",
        help="Optional UTF-8 JSON file receiving prompt id, timing, and ComfyUI outputs",
    )
    args = parser.parse_args()

    if args.prompt_file:
        prompt_config = json.loads(Path(args.prompt_file).read_text(encoding="utf-8"))
        args.prompt = prompt_config["prompt"]

    system_stats = request_json(f"{args.server}/system_stats")
    print("ComfyUI:", system_stats["system"]["comfyui_version"])
    print("PyTorch:", system_stats["system"]["pytorch_version"])
    print("Device:", system_stats["devices"][0]["name"])

    prompt = build_prompt(args)
    record_path = Path(args.record)
    record_path.parent.mkdir(parents=True, exist_ok=True)
    record_path.write_text(json.dumps(prompt, indent=2) + "\n", encoding="utf-8")

    started_at = time.time()
    print(f"generation_start_epoch={started_at:.3f}")
    submitted = request_json(f"{args.server}/prompt", method="POST", payload={"prompt": prompt})
    prompt_id = submitted["prompt_id"]
    print("prompt_id=", prompt_id)

    deadline = started_at + args.timeout_seconds
    while time.time() < deadline:
        history = request_json(f"{args.server}/history/{prompt_id}")
        item = history.get(prompt_id)
        if item:
            status = item.get("status", {})
            status_str = status.get("status_str")
            completed = status.get("completed", False)
            print(
                f"poll_epoch={time.time():.3f} status={status_str} completed={completed}",
                flush=True,
            )
            if status_str == "error":
                print(json.dumps(item, indent=2))
                return 1
            if completed:
                ended_at = time.time()
                outputs = item.get("outputs", {})
                print(f"generation_end_epoch={ended_at:.3f}")
                print(f"generation_duration_seconds={ended_at - started_at:.3f}")
                print(json.dumps(outputs, indent=2))
                if args.result_record:
                    result_path = Path(args.result_record)
                    result_path.parent.mkdir(parents=True, exist_ok=True)
                    result_path.write_text(
                        json.dumps(
                            {
                                "prompt_id": prompt_id,
                                "generation_start_epoch": started_at,
                                "generation_end_epoch": ended_at,
                                "generation_duration_seconds": ended_at - started_at,
                                "outputs": outputs,
                            },
                            indent=2,
                        )
                        + "\n",
                        encoding="utf-8",
                    )
                return 0
        time.sleep(args.poll_seconds)

    print(f"Timed out after {args.timeout_seconds} seconds")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
