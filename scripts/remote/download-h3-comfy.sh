#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/root/autodl-tmp/h3}"
MODEL_ROOT="${MODEL_ROOT:-${DATA_ROOT}/comfyui-models}"
MODEL_REPO="Comfy-Org/MiniMax-H3"
MODEL_REVISION="fd70b39279d1ae6eb214c903f53e1bec3af19a77"

if [[ "${USE_NETWORK_TURBO:-1}" == "1" && -f /etc/network_turbo ]]; then
  # AutoDL academic acceleration for huggingface.co. Do not combine this with
  # hf-mirror.com; the two proxy layers were slower and caused Xet/Range errors.
  # shellcheck disable=SC1091
  source /etc/network_turbo >/dev/null
fi

export HF_ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"
export HF_HOME="${HF_HOME:-${DATA_ROOT}/cache/huggingface}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-${HF_HOME}/hub}"
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"
export TMPDIR="${TMPDIR:-${DATA_ROOT}/tmp}"

mkdir -p \
  "${MODEL_ROOT}" \
  "${HF_HOME}" \
  "${HUGGINGFACE_HUB_CACHE}" \
  "${TMPDIR}" \
  "${DATA_ROOT}/logs"

start_epoch="$(date +%s)"
printf 'download_start=%s epoch=%s revision=%s\n' \
  "$(date -Is)" "${start_epoch}" "${MODEL_REVISION}" \
  | tee "${DATA_ROOT}/logs/comfy-h3-download-status.txt"

# Pass files as explicit positional arguments. With hf 1.26, placing several
# values after one --include option can cause the first pattern to be ignored.
hf download "${MODEL_REPO}" \
  diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors \
  text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors \
  vae/minimax_h3_video_vae_fp16.safetensors \
  vae/minimax_h3_audio_vae_fp32.safetensors \
  --revision "${MODEL_REVISION}" \
  --local-dir "${MODEL_ROOT}"

unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy

end_epoch="$(date +%s)"
printf 'download_end=%s epoch=%s rc=0 duration_seconds=%s\n' \
  "$(date -Is)" "${end_epoch}" "$((end_epoch - start_epoch))" \
  | tee -a "${DATA_ROOT}/logs/comfy-h3-download-status.txt"
