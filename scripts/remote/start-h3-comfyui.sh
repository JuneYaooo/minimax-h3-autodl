#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/root/autodl-tmp/h3}"
COMFYUI_ROOT="${COMFYUI_ROOT:-/root/ComfyUI}"
# Bind locally by default. Use an SSH tunnel for browser access; explicitly
# override LISTEN_HOST only when the surrounding network policy is understood.
LISTEN_HOST="${LISTEN_HOST:-127.0.0.1}"
LISTEN_PORT="${LISTEN_PORT:-8188}"
RESERVE_VRAM_GB="${RESERVE_VRAM_GB:-2}"
PYTHON_BIN="${PYTHON_BIN:-/root/miniconda3/bin/python}"

export HF_HOME="${HF_HOME:-${DATA_ROOT}/cache/huggingface}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-${HF_HOME}/hub}"
export TORCH_HOME="${TORCH_HOME:-${DATA_ROOT}/cache/torch}"
export TMPDIR="${TMPDIR:-${DATA_ROOT}/tmp}"
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"

# The academic proxy is useful during Git/Hugging Face downloads but AutoDL
# recommends disabling it for normal service operation.
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy

mkdir -p \
  "${DATA_ROOT}/inputs" \
  "${DATA_ROOT}/outputs" \
  "${DATA_ROOT}/logs" \
  "${DATA_ROOT}/tmp/comfyui"

for required in \
  "${COMFYUI_ROOT}/main.py" \
  "${DATA_ROOT}/deploy/extra_model_paths.yaml"; do
  if [[ ! -f "${required}" ]]; then
    printf 'Required file not found: %s\n' "${required}" >&2
    exit 1
  fi
done

if [[ ! -x "${PYTHON_BIN}" ]]; then
  printf 'Python interpreter not executable: %s\n' "${PYTHON_BIN}" >&2
  exit 1
fi

cd "${COMFYUI_ROOT}"
exec "${PYTHON_BIN}" main.py \
  --listen "${LISTEN_HOST}" \
  --port "${LISTEN_PORT}" \
  --reserve-vram "${RESERVE_VRAM_GB}" \
  --extra-model-paths-config "${DATA_ROOT}/deploy/extra_model_paths.yaml" \
  --input-directory "${DATA_ROOT}/inputs" \
  --output-directory "${DATA_ROOT}/outputs" \
  --temp-directory "${DATA_ROOT}/tmp/comfyui" \
  "$@"
