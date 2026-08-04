#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_ROOT="${MODEL_ROOT:-/root/autodl-tmp/h3/comfyui-models}"

cd "${MODEL_ROOT}"

cat > /tmp/minimax-h3-sha256.txt <<'CHECKSUMS'
e889202c41dafb67b10d67b97f0d8541508036a6090af23425a5c2615d03c47a  diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors
35a88d51044231fe332301d7a62aa81e3f2cba62febeb446e2c1e3e0ef76f2c6  text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
7c1f131492e7eddacaac9069a61b81bdd39de5cc96561e677c5eab1cdce5e522  vae/minimax_h3_video_vae_fp16.safetensors
8e505d95dd1561d47abd43d4238fd40d9bb1ae9e147ed0a4cba778d76ae4db48  vae/minimax_h3_audio_vae_fp32.safetensors
CHECKSUMS

python - <<'PY'
from pathlib import Path

expected = {
    "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors": 20_970_379_616,
    "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors": 15_687_142_551,
    "vae/minimax_h3_video_vae_fp16.safetensors": 5_207_808_496,
    "vae/minimax_h3_audio_vae_fp32.safetensors": 605_254_808,
}

for name, size in expected.items():
    path = Path(name)
    actual = path.stat().st_size if path.is_file() else None
    if actual != size:
        raise SystemExit(f"Size mismatch: {name}: expected={size}, actual={actual}")
    with path.open("rb") as handle:
        header_size = int.from_bytes(handle.read(8), "little")
    if not 2 <= header_size <= 100_000_000:
        raise SystemExit(f"Invalid safetensors header length: {name}: {header_size}")
    print(f"size/header OK: {size} bytes: {name}")
PY

sha256sum --check /tmp/minimax-h3-sha256.txt
rm -f /tmp/minimax-h3-sha256.txt

