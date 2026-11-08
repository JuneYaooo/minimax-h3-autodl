#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/root/autodl-tmp/h3}"
SERVICE_SCREEN="${SERVICE_SCREEN:-h3-comfyui}"
START_SCRIPT="${START_SCRIPT:-${DATA_ROOT}/deploy/start-h3-comfyui.sh}"
CHECK_SERVICE_SCRIPT="${CHECK_SERVICE_SCRIPT:-${DATA_ROOT}/deploy/check-h3-service.py}"
VALIDATE_SCRIPT="${VALIDATE_SCRIPT:-${DATA_ROOT}/deploy/validate-h3-deployment.sh}"
PYTHON_BIN="${PYTHON_BIN:-/root/miniconda3/bin/python}"
SERVICE_LOG="${SERVICE_LOG:-${DATA_ROOT}/logs/comfyui-restart.log}"
EXPECTED_COMFYUI="${EXPECTED_COMFYUI:-0.30.0}"
EXPECTED_PYTORCH="${EXPECTED_PYTORCH:-2.13.0+cu130}"
EXPECTED_DEVICE="${EXPECTED_DEVICE:-NVIDIA GeForce RTX 5090}"
STOP_TIMEOUT_SECONDS="${STOP_TIMEOUT_SECONDS:-60}"
START_TIMEOUT_SECONDS="${START_TIMEOUT_SECONDS:-120}"
RESTART_LOCK="${RESTART_LOCK:-${DATA_ROOT}/tmp/h3-restart.lock}"
RESTART_RUN_VALIDATION_SMOKE="${RESTART_RUN_VALIDATION_SMOKE:-1}"
RESTART_VALIDATION_MODE="${RESTART_VALIDATION_MODE:-full}"

comfyui_pids() {
  pgrep -f 'python([0-9.]*)? .*main\.py .*--listen' 2>/dev/null || true
}

check_service() {
  "${PYTHON_BIN}" "${CHECK_SERVICE_SCRIPT}" \
    --expected-comfyui "${EXPECTED_COMFYUI}" \
    --expected-pytorch "${EXPECTED_PYTORCH}" \
    --expected-device "${EXPECTED_DEVICE}"
}

wait_for_pid_exit() {
  local pid="$1" deadline
  deadline=$((SECONDS + STOP_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

for required in "${PYTHON_BIN}" "${START_SCRIPT}" "${CHECK_SERVICE_SCRIPT}" "${VALIDATE_SCRIPT}"; do
  if [[ ! -e "${required}" ]]; then
    printf 'Required path missing: %s\n' "${required}" >&2
    exit 1
  fi
done
if [[ ! -x "${PYTHON_BIN}" || ! -x "${START_SCRIPT}" || ! -x "${VALIDATE_SCRIPT}" ]]; then
  printf 'Python, starter, and validator must be executable\n' >&2
  exit 1
fi
for command_name in flock pgrep screen; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "${command_name}" >&2
    exit 1
  fi
done
if [[ "${RESTART_VALIDATION_MODE}" != "full" && "${RESTART_VALIDATION_MODE}" != "health" ]]; then
  printf 'RESTART_VALIDATION_MODE must be full or health\n' >&2
  exit 1
fi

mkdir -p "${DATA_ROOT}/tmp"
exec 9>"${RESTART_LOCK}"
if ! flock -n 9; then
  printf 'Another H3 restart is already in progress: %s\n' "${RESTART_LOCK}" >&2
  exit 1
fi

# This preflight rejects a busy queue. Never restart over an active task.
check_service >/dev/null

mapfile -t old_pids < <(comfyui_pids)
if (( ${#old_pids[@]} != 1 )); then
  printf 'Expected exactly one ComfyUI process before restart, got %s\n' "${#old_pids[@]}" >&2
  exit 1
fi
old_pid="${old_pids[0]}"

if ! screen -list 2>/dev/null | grep -qE "[0-9]+\.${SERVICE_SCREEN}[[:space:]]"; then
  printf 'Required screen session is missing: %s\n' "${SERVICE_SCREEN}" >&2
  exit 1
fi

screen -S "${SERVICE_SCREEN}" -X quit
if ! wait_for_pid_exit "${old_pid}"; then
  kill -TERM "${old_pid}"
  if ! wait_for_pid_exit "${old_pid}"; then
    printf 'ComfyUI process did not exit after SIGTERM: %s\n' "${old_pid}" >&2
    exit 1
  fi
fi

mkdir -p "${DATA_ROOT}/logs"
screen -dmS "${SERVICE_SCREEN}" bash -lc \
  'exec "$1" >>"$2" 2>&1' _ "${START_SCRIPT}" "${SERVICE_LOG}"

deadline=$((SECONDS + START_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  if check_service >/dev/null 2>&1; then
    mapfile -t new_pids < <(comfyui_pids)
    if (( ${#new_pids[@]} == 1 )) && [[ "${new_pids[0]}" != "${old_pid}" ]] \
      && screen -list 2>/dev/null | grep -qE "[0-9]+\.${SERVICE_SCREEN}[[:space:]]"; then
      if [[ "${RESTART_VALIDATION_MODE}" == "health" ]]; then
        exit 0
      fi
      if [[ "${RESTART_RUN_VALIDATION_SMOKE}" == "1" ]]; then
        exec "${VALIDATE_SCRIPT}"
      fi
      RUN_FL2VA_SMOKE=0 RUN_REF2VA_SMOKE=0 exec "${VALIDATE_SCRIPT}"
    fi
  fi
  sleep 2
done

printf 'ComfyUI did not become healthy within %s seconds\n' "${START_TIMEOUT_SECONDS}" >&2
exit 1
