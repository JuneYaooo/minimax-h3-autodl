#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/root/autodl-tmp/h3}"
COMFYUI_ROOT="${COMFYUI_ROOT:-/root/ComfyUI}"
COMFYUI_TAG="v0.30.0"

export PIP_CACHE_DIR="${PIP_CACHE_DIR:-${DATA_ROOT}/cache/pip}"
export TMPDIR="${TMPDIR:-${DATA_ROOT}/tmp}"

mkdir -p "${DATA_ROOT}"/{cache/pip,tmp,logs,deploy,inputs,outputs,workflows}

start_epoch="$(date +%s)"
printf 'install_start=%s epoch=%s tag=%s\n' \
  "$(date -Is)" "${start_epoch}" "${COMFYUI_TAG}" \
  | tee "${DATA_ROOT}/logs/comfy-install-status.txt"

if [[ ! -d "${COMFYUI_ROOT}/.git" ]]; then
  source /etc/network_turbo
  git clone --branch "${COMFYUI_TAG}" --depth 1 \
    https://github.com/Comfy-Org/ComfyUI.git "${COMFYUI_ROOT}"
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
else
  current_tag="$(git -C "${COMFYUI_ROOT}" describe --tags --exact-match 2>/dev/null || true)"
  if [[ "${current_tag}" != "${COMFYUI_TAG}" ]]; then
    printf 'Expected ComfyUI %s, found %s\n' \
      "${COMFYUI_TAG}" "${current_tag:-an untagged checkout}" >&2
    exit 1
  fi
fi

# RTX 5090 and the optimized comfy-kitchen CUDA backend require CUDA 13.0+.
# Install the three PyTorch packages from one index so their CUDA runtimes stay
# coherent; installing requirements on top of an older base image otherwise
# selected a cu13 torchaudio next to cu128 torch/torchvision.
python -m pip install --upgrade \
  torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu130
python -m pip install -r "${COMFYUI_ROOT}/requirements.txt"
install -m 0644 "${DATA_ROOT}/deploy/extra_model_paths.yaml" \
  "${COMFYUI_ROOT}/extra_model_paths.yaml"

end_epoch="$(date +%s)"
printf 'install_end=%s epoch=%s rc=0 duration_seconds=%s\n' \
  "$(date -Is)" "${end_epoch}" "$((end_epoch - start_epoch))" \
  | tee -a "${DATA_ROOT}/logs/comfy-install-status.txt"
printf 'comfy_commit=%s\n' "$(git -C "${COMFYUI_ROOT}" rev-parse HEAD)" \
  | tee -a "${DATA_ROOT}/logs/comfy-install-status.txt"
