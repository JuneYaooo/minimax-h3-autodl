#!/usr/bin/env python3
"""Perform read-only MiniMax H3 service preflight checks against ComfyUI."""

from __future__ import annotations

import argparse
import json
import urllib.error
import urllib.request
from pathlib import Path


REQUIRED_NODES = {
    "CLIPLoader",
    "CreateVideo",
    "MiniMaxH3ImageToVideo",
    "MiniMaxH3ReferenceToVideo",
    "SaveVideo",
    "UNETLoader",
    "VAEDecodeAudio",
    "VAELoader",
}
REQUIRED_MODELS = {
    "UNETLoader": {
        "unet_name": {
            "minimax_h3_fl2va_pruned_int8_convrot.safetensors",
            "minimax_h3_ref2va_pruned_int8_convrot.safetensors",
        }
    },
    "CLIPLoader": {
        "clip_name": {"qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"}
    },
    "VAELoader": {
        "vae_name": {
            "minimax_h3_video_vae_fp16.safetensors",
            "minimax_h3_audio_vae_fp32.safetensors",
        }
    },
}


def request_json(url: str, timeout: float) -> dict:
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if response.status != 200:
                raise RuntimeError(f"HTTP {response.status} from {url}")
            payload = json.load(response)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} from {url}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Unable to reach {url}: {exc.reason}") from exc
    if not isinstance(payload, dict):
        raise RuntimeError(f"Expected a JSON object from {url}")
    return payload


def choice_values(object_info: dict, node_name: str, field_name: str) -> set[str]:
    try:
        specification = object_info[node_name]["input"]["required"][field_name]
        values = specification[0]
    except (KeyError, IndexError, TypeError) as exc:
        raise ValueError(f"Unable to read {node_name}.{field_name} choices") from exc
    if not isinstance(values, list) or not all(isinstance(item, str) for item in values):
        raise ValueError(f"Invalid {node_name}.{field_name} choice schema")
    return set(values)


def validate_service(
    system_stats: dict,
    queue: dict,
    object_info: dict,
    *,
    expected_comfyui: str,
    expected_pytorch: str,
    expected_device: str,
) -> dict:
    try:
        actual_comfyui = str(system_stats["system"]["comfyui_version"])
        actual_pytorch = str(system_stats["system"]["pytorch_version"])
        devices = system_stats["devices"]
        actual_device = str(devices[0]["name"])
    except (KeyError, IndexError, TypeError) as exc:
        raise ValueError("Invalid /system_stats response") from exc

    if actual_comfyui != expected_comfyui:
        raise ValueError(
            f"ComfyUI version mismatch: expected={expected_comfyui}, actual={actual_comfyui}"
        )
    if actual_pytorch != expected_pytorch:
        raise ValueError(
            f"PyTorch version mismatch: expected={expected_pytorch}, actual={actual_pytorch}"
        )
    if expected_device not in actual_device:
        raise ValueError(
            f"GPU mismatch: expected substring={expected_device!r}, actual={actual_device!r}"
        )

    running = queue.get("queue_running")
    pending = queue.get("queue_pending")
    if not isinstance(running, list) or not isinstance(pending, list):
        raise ValueError("Invalid /queue response")
    if running or pending:
        raise ValueError(
            f"ComfyUI queue is not empty: running={len(running)}, pending={len(pending)}"
        )

    missing_nodes = sorted(REQUIRED_NODES.difference(object_info))
    if missing_nodes:
        raise ValueError(f"Missing required ComfyUI nodes: {', '.join(missing_nodes)}")

    missing_models: list[str] = []
    for node_name, fields in REQUIRED_MODELS.items():
        for field_name, required in fields.items():
            available = choice_values(object_info, node_name, field_name)
            missing_models.extend(sorted(required.difference(available)))
    if missing_models:
        raise ValueError(f"Models not visible to ComfyUI: {', '.join(missing_models)}")

    return {
        "comfyui_version": actual_comfyui,
        "pytorch_version": actual_pytorch,
        "device": actual_device,
        "queue_running": 0,
        "queue_pending": 0,
        "required_node_count": len(REQUIRED_NODES),
        "required_model_count": sum(
            len(required)
            for fields in REQUIRED_MODELS.values()
            for required in fields.values()
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", default="http://127.0.0.1:8188")
    parser.add_argument("--expected-comfyui", default="0.30.0")
    parser.add_argument("--expected-pytorch", default="2.13.0+cu130")
    parser.add_argument("--expected-device", default="NVIDIA GeForce RTX 5090")
    parser.add_argument("--timeout-seconds", type=float, default=30.0)
    parser.add_argument("--summary-record")
    args = parser.parse_args()

    if args.timeout_seconds <= 0:
        raise SystemExit("timeout-seconds must be positive")

    system_stats = request_json(f"{args.server}/system_stats", args.timeout_seconds)
    queue = request_json(f"{args.server}/queue", args.timeout_seconds)
    object_info = request_json(f"{args.server}/object_info", args.timeout_seconds)
    summary = validate_service(
        system_stats,
        queue,
        object_info,
        expected_comfyui=args.expected_comfyui,
        expected_pytorch=args.expected_pytorch,
        expected_device=args.expected_device,
    )
    serialized = json.dumps(summary, ensure_ascii=False, indent=2) + "\n"
    print(serialized, end="")
    if args.summary_record:
        output_path = Path(args.summary_record)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(serialized, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
