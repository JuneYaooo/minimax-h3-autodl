#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/root/autodl-tmp/h3}"
COMFYUI_ROOT="${COMFYUI_ROOT:-/root/ComfyUI}"
OUT_DIR="${OUT_DIR:-${DATA_ROOT}/deploy/environment-snapshot}"

mkdir -p "${OUT_DIR}"

date -Is > "${OUT_DIR}/captured-at.txt"

{
  uname -a
  echo
  command -v python || true
  python --version 2>&1 || true
  echo
  command -v pip || true
  pip --version 2>&1 || true
} > "${OUT_DIR}/system.txt"

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi > "${OUT_DIR}/nvidia-smi.txt"
fi

python - <<'PY' > "${OUT_DIR}/torch-info.txt" 2>&1 || true
try:
    import torch
    print("torch:", torch.__version__)
    print("torch cuda:", torch.version.cuda)
    print("cuda available:", torch.cuda.is_available())
    print("cuda device count:", torch.cuda.device_count())
    for index in range(torch.cuda.device_count()):
        print(f"gpu {index}:", torch.cuda.get_device_name(index))
except Exception as exc:
    print("Unable to inspect torch:", repr(exc))
PY

pip freeze > "${OUT_DIR}/requirements-lock.txt" 2>&1 || true

if command -v conda >/dev/null 2>&1; then
  conda env export > "${OUT_DIR}/conda-environment.yml" 2>&1 || true
  conda info > "${OUT_DIR}/conda-info.txt" 2>&1 || true
fi

df -h > "${OUT_DIR}/disk-free.txt"
free -h > "${OUT_DIR}/memory.txt" 2>&1 || true

if [[ -d "${COMFYUI_ROOT}/.git" ]]; then
  git -C "${COMFYUI_ROOT}" status --short \
    > "${OUT_DIR}/comfyui-status.txt" 2>&1 || true
  git -C "${COMFYUI_ROOT}" rev-parse HEAD \
    > "${OUT_DIR}/comfyui-commit.txt" 2>&1 || true
fi

if [[ -d "${COMFYUI_ROOT}/custom_nodes" ]]; then
  : > "${OUT_DIR}/custom-node-commits.txt"
  while IFS= read -r git_dir; do
    node_dir="${git_dir%/.git}"
    commit="$(git -C "${node_dir}" rev-parse HEAD 2>/dev/null || echo unknown)"
    printf '%s\t%s\n' "${node_dir}" "${commit}" \
      >> "${OUT_DIR}/custom-node-commits.txt"
  done < <(find "${COMFYUI_ROOT}/custom_nodes" -mindepth 2 -maxdepth 2 -type d -name .git | sort)
fi

if [[ -d "${DATA_ROOT}/models" ]]; then
  du -sh "${DATA_ROOT}/models" > "${OUT_DIR}/model-total-size.txt" 2>&1 || true
  find "${DATA_ROOT}/models" -type f -printf '%s\t%p\n' \
    | sort -nr \
    | head -100 \
    > "${OUT_DIR}/largest-model-files.txt" || true
fi

echo "Environment snapshot written to: ${OUT_DIR}"

