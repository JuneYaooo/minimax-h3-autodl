#!/usr/bin/env python3
"""Submit and monitor a MiniMax H3 Ref2VA smoke test to local ComfyUI."""

from __future__ import annotations

import argparse
import json
import time
import urllib.error
import urllib.request
from pathlib import Path, PurePosixPath


IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp"}
VIDEO_SUFFIXES = {".mp4", ".mov", ".webm", ".mkv"}
AUDIO_SUFFIXES = {".wav", ".mp3", ".m4a", ".aac", ".flac", ".ogg"}


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


def normalize_input_path(raw: object, suffixes: set[str], label: str) -> str:
    if not isinstance(raw, str) or not raw.strip():
        raise ValueError(f"{label} must be a non-empty string")
    item = PurePosixPath(raw.strip())
    if item.is_absolute() or ".." in item.parts:
        raise ValueError(f"{label} must be input-relative: {raw!r}")
    if item.suffix.lower() not in suffixes:
        raise ValueError(f"unsupported {label} extension: {raw!r}")
    return item.as_posix()


def validate_generation_args(args: argparse.Namespace) -> None:
    if args.width <= 0 or args.height <= 0 or args.width % 32 or args.height % 32:
        raise ValueError("width and height must be positive multiples of 32")
    if args.length < 5 or (args.length - 5) % 17:
        raise ValueError("length must satisfy 17n+5")
    if not 1 <= args.steps <= 100:
        raise ValueError("steps must be between 1 and 100")
    if args.poll_seconds <= 0:
        raise ValueError("poll-seconds must be positive")
    if args.timeout_seconds <= 0:
        raise ValueError("timeout-seconds must be positive")


def load_references(path: Path) -> dict:
    payload = json.loads(path.read_text(encoding="utf-8"))

    images = [
        normalize_input_path(item, IMAGE_SUFFIXES, "reference image")
        for item in payload.get("reference_images", [])
    ]

    videos: list[dict[str, object]] = []
    for item in payload.get("reference_videos", []):
        if isinstance(item, str):
            raw_path = item
            include_audio = False
        elif isinstance(item, dict):
            raw_path = item.get("path")
            include_audio = bool(item.get("include_audio", False))
        else:
            raise ValueError("each reference video must be a string or object")
        videos.append(
            {
                "path": normalize_input_path(raw_path, VIDEO_SUFFIXES, "reference video"),
                "include_audio": include_audio,
            }
        )

    audios = [
        normalize_input_path(item, AUDIO_SUFFIXES, "reference audio")
        for item in payload.get("reference_audios", [])
    ]

    if len(images) > 9:
        raise ValueError("reference_images supports at most 9 files")
    if len(videos) > 3:
        raise ValueError("reference_videos supports at most 3 files")
    if len(audios) > 3:
        raise ValueError("reference_audios supports at most 3 files")
    if not images and not videos:
        raise ValueError("Ref2VA requires at least one reference image or video")
    if len(images) + len(videos) + len(audios) > 12:
        raise ValueError("the total number of reference files must not exceed 12")

    image_size = str(payload.get("ref_image_size", "match")).strip().lower()
    if image_size not in {"match", "max"}:
        raise ValueError("ref_image_size must be 'match' or 'max'")

    return {
        "images": images,
        "videos": videos,
        "audios": audios,
        "ref_image_size": image_size,
    }


def build_prompt(args: argparse.Namespace, references: dict) -> dict:
    graph: dict[str, dict] = {
        "1": {
            "class_type": "UNETLoader",
            "inputs": {
                "unet_name": args.unet_name,
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
            "class_type": "MiniMaxH3ReferenceToVideo",
            "inputs": {
                "clip": ["2", 0],
                "vae": ["3", 0],
                "audio_vae": ["4", 0],
                "prompt": args.prompt,
                "width": args.width,
                "height": args.height,
                "length": args.length,
                "ref_image_size": references["ref_image_size"],
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
        "7": {"class_type": "RandomNoise", "inputs": {"noise_seed": args.seed}},
        "8": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "res_multistep"}},
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
        "11": {"class_type": "VAEDecode", "inputs": {"samples": ["10", 0], "vae": ["3", 0]}},
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
                "codec": "auto",
            },
        },
    }

    next_node = 20
    for index, image_name in enumerate(references["images"]):
        node_id = str(next_node)
        next_node += 1
        graph[node_id] = {"class_type": "LoadImage", "inputs": {"image": image_name}}
        graph["5"]["inputs"][f"ref_images.ref_image_{index}"] = [node_id, 0]

    for index, video in enumerate(references["videos"]):
        load_id = str(next_node)
        components_id = str(next_node + 1)
        next_node += 2
        graph[load_id] = {"class_type": "LoadVideo", "inputs": {"file": video["path"]}}
        graph[components_id] = {
            "class_type": "GetVideoComponents",
            "inputs": {"video": [load_id, 0]},
        }
        graph["5"]["inputs"][f"ref_videos.ref_video_{index}"] = [components_id, 0]
        if video["include_audio"]:
            graph["5"]["inputs"][f"ref_video_audios.ref_video_audio_{index}"] = [
                components_id,
                1,
            ]

    for index, audio_name in enumerate(references["audios"]):
        node_id = str(next_node)
        next_node += 1
        graph[node_id] = {"class_type": "LoadAudio", "inputs": {"audio": audio_name}}
        graph["5"]["inputs"][f"ref_audios.ref_audio_{index}"] = [node_id, 0]

    return graph


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", default="http://127.0.0.1:8188")
    parser.add_argument(
        "--unet-name",
        default="minimax_h3_ref2va_pruned_int8_convrot.safetensors",
    )
    parser.add_argument("--width", type=int, default=608)
    parser.add_argument("--height", type=int, default=352)
    parser.add_argument("--length", type=int, default=56)
    parser.add_argument("--steps", type=int, default=5)
    parser.add_argument("--seed", type=int, default=20260803)
    parser.add_argument("--prompt-file", required=True)
    parser.add_argument("--references-file", required=True)
    parser.add_argument("--filename-prefix", required=True)
    parser.add_argument("--record", required=True)
    parser.add_argument("--result-record", required=True)
    parser.add_argument("--poll-seconds", type=float, default=5.0)
    parser.add_argument("--timeout-seconds", type=int, default=7200)
    args = parser.parse_args()

    validate_generation_args(args)

    args.prompt = json.loads(Path(args.prompt_file).read_text(encoding="utf-8"))["prompt"]
    references = load_references(Path(args.references_file))

    system_stats = request_json(f"{args.server}/system_stats")
    print("ComfyUI:", system_stats["system"]["comfyui_version"])
    print("PyTorch:", system_stats["system"]["pytorch_version"])
    print("Device:", system_stats["devices"][0]["name"])

    prompt = build_prompt(args, references)
    record_path = Path(args.record)
    record_path.parent.mkdir(parents=True, exist_ok=True)
    record_path.write_text(json.dumps(prompt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

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
            print(f"poll_epoch={time.time():.3f} status={status_str} completed={completed}", flush=True)
            if status_str == "error":
                print(json.dumps(item, ensure_ascii=False, indent=2))
                return 1
            if completed:
                ended_at = time.time()
                outputs = item.get("outputs", {})
                print(f"generation_end_epoch={ended_at:.3f}")
                print(f"generation_duration_seconds={ended_at - started_at:.3f}")
                print(json.dumps(outputs, ensure_ascii=False, indent=2))
                result_path = Path(args.result_record)
                result_path.parent.mkdir(parents=True, exist_ok=True)
                result_path.write_text(
                    json.dumps(
                        {
                            "prompt_id": prompt_id,
                            "unet_name": args.unet_name,
                            "generation_start_epoch": started_at,
                            "generation_end_epoch": ended_at,
                            "generation_duration_seconds": ended_at - started_at,
                            "reference_image_count": len(references["images"]),
                            "reference_video_count": len(references["videos"]),
                            "reference_video_audio_count": sum(
                                bool(video["include_audio"])
                                for video in references["videos"]
                            ),
                            "reference_audio_count": len(references["audios"]),
                            "ref_image_size": references["ref_image_size"],
                            "outputs": outputs,
                        },
                        ensure_ascii=False,
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
