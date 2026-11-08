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
MEMORY_WATCH_ENABLED="${MEMORY_WATCH_ENABLED:-1}"
MEMORY_WATCH_SCRIPT="${MEMORY_WATCH_SCRIPT:-${DATA_ROOT}/deploy/watch-h3-memory.sh}"
MEMORY_WATCH_LOG="${MEMORY_WATCH_LOG:-${DATA_ROOT}/logs/h3-memory-watch.log}"
MEMORY_WATCH_SCREEN="${MEMORY_WATCH_SCREEN:-h3-memory-watch}"
RESTART_AFTER_EACH_TASK="${RESTART_AFTER_EACH_TASK:-1}"
export RESTART_AFTER_EACH_TASK

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

if [[ "${MEMORY_WATCH_ENABLED}" != "0" && "${MEMORY_WATCH_ENABLED}" != "1" ]]; then
  printf 'MEMORY_WATCH_ENABLED must be 0 or 1\n' >&2
  exit 1
fi
if [[ "${MEMORY_WATCH_ENABLED}" == "1" && ! -x "${MEMORY_WATCH_SCRIPT}" ]]; then
  printf 'Memory watcher not executable: %s\n' "${MEMORY_WATCH_SCRIPT}" >&2
  exit 1
fi
if [[ "${MEMORY_WATCH_ENABLED}" == "1" ]]; then
  if ! command -v screen >/dev/null 2>&1; then
    printf 'Required command not found: screen\n' >&2
    exit 1
  fi
  if ! screen -list 2>/dev/null | grep -qE "[0-9]+\.${MEMORY_WATCH_SCREEN}[[:space:]]"; then
    screen -dmS "${MEMORY_WATCH_SCREEN}" bash -lc \
      'exec "$1" >>"$2" 2>&1' _ "${MEMORY_WATCH_SCRIPT}" "${MEMORY_WATCH_LOG}"
  fi
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
