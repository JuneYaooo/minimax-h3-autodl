#!/usr/bin/env bash
set -Eeuo pipefail

# Idle-only memory guard. It never interrupts a running/pending ComfyUI task.

DATA_ROOT="${DATA_ROOT:-/root/autodl-tmp/h3}"
COMFYUI_URL="${COMFYUI_URL:-http://127.0.0.1:8188}"
PYTHON_BIN="${PYTHON_BIN:-/root/miniconda3/bin/python}"
SERVICE_SCREEN="${SERVICE_SCREEN:-h3-comfyui}"
RESTART_SCRIPT="${RESTART_SCRIPT:-${DATA_ROOT}/deploy/restart-h3-comfyui.sh}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-30}"
POST_RESTART_WAIT_SECONDS="${POST_RESTART_WAIT_SECONDS:-10}"
RESTART_AFTER_EACH_TASK="${RESTART_AFTER_EACH_TASK:-1}"
WATCH_LOCK="${WATCH_LOCK:-${DATA_ROOT}/tmp/h3-memory-watch.lock}"
WATCH_LOG="${WATCH_LOG:-${DATA_ROOT}/logs/h3-memory-watch.log}"
CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"

mkdir -p "${DATA_ROOT}/tmp" "${DATA_ROOT}/logs"
for command_name in curl flock pgrep screen; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf '%s required_command_missing=%s action=stop_watch\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${command_name}" >&2
    exit 69
  fi
done
if [[ ! -x "${PYTHON_BIN}" || ! -x "${RESTART_SCRIPT}" ]]; then
  printf '%s required_executable_missing python=%s restart=%s action=stop_watch\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${PYTHON_BIN}" "${RESTART_SCRIPT}" >&2
  exit 69
fi
if [[ "${RESTART_AFTER_EACH_TASK}" != "0" && "${RESTART_AFTER_EACH_TASK}" != "1" ]]; then
  printf '%s RESTART_AFTER_EACH_TASK_must_be_0_or_1 action=stop_watch\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >&2
  exit 64
fi
exec 9>"${WATCH_LOCK}"
if ! flock -n 9; then
  exit 0
fi

timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

numeric_bytes() {
  local value="${1:-}"
  [[ "${value}" =~ ^[0-9]+$ ]] && (( ${#value} <= 15 ))
}

cgroup_value() {
  local key="$1"
  if [[ -r "${CGROUP_ROOT}/${key}" ]]; then
    cat "${CGROUP_ROOT}/${key}"
  elif [[ "${key}" == "memory.current" && -r "${CGROUP_ROOT}/memory/memory_usage_in_bytes" ]]; then
    cat "${CGROUP_ROOT}/memory/memory_usage_in_bytes"
  elif [[ "${key}" == "memory.high" && -r "${CGROUP_ROOT}/memory/memory.soft_limit_in_bytes" ]]; then
    cat "${CGROUP_ROOT}/memory/memory.soft_limit_in_bytes"
  elif [[ "${key}" == "memory.max" && -r "${CGROUP_ROOT}/memory/memory.limit_in_bytes" ]]; then
    cat "${CGROUP_ROOT}/memory/memory.limit_in_bytes"
  else
    printf ''
  fi
}

comfyui_pid_count() {
  pgrep -f 'python([0-9.]*)? .*main\.py .*--listen' 2>/dev/null | wc -l | tr -d ' '
}

queue_state() {
  local queue_json
  queue_json="$(curl -fsS --max-time 5 "${COMFYUI_URL}/queue" 2>/dev/null)" || return 1
  "${PYTHON_BIN}" -c '
import json, sys
q = json.load(sys.stdin)
print("empty" if not q.get("queue_running") and not q.get("queue_pending") else "busy")
' <<<"${queue_json}"
}

restart_service() {
  local reason="$1" threshold="${2:-}" after
  printf '%s action=restart reason=%s threshold=%s\n' "$(timestamp)" "${reason}" "${threshold:-none}" >&2
  RESTART_VALIDATION_MODE=health RESTART_RUN_VALIDATION_SMOKE=0 "${RESTART_SCRIPT}"
  sleep "${POST_RESTART_WAIT_SECONDS}"
  after="$(cgroup_value memory.current)"
  if [[ -n "${threshold}" ]] && numeric_bytes "${after}" && [[ "${after}" -ge "${threshold}" ]]; then
    printf '%s post_restart_memory_still_high current=%s threshold=%s action=stop_watch\n' \
      "$(timestamp)" "${after}" "${threshold}" >&2
    return 1
  fi
  printf '%s post_restart_memory_ok current=%s threshold=%s\n' \
    "$(timestamp)" "${after:-unknown}" "${threshold:-none}" >&2
}

restart_if_idle_and_high() {
  local current high max threshold max_threshold high_threshold

  current="$(cgroup_value memory.current)"
  high="$(cgroup_value memory.high)"
  max="$(cgroup_value memory.max)"
  numeric_bytes "${current}" || return 0
  numeric_bytes "${high}" || high=''
  numeric_bytes "${max}" || max=''

  threshold=''
  if numeric_bytes "${max}"; then
    max_threshold=$((max * 85 / 100))
    threshold="${max_threshold}"
  fi
  if numeric_bytes "${high}"; then
    high_threshold=$((high * 92 / 100))
    if [[ -z "${threshold}" || "${high_threshold}" -lt "${threshold}" ]]; then
      threshold="${high_threshold}"
    fi
  fi
  [[ -n "${threshold}" && "${current}" -ge "${threshold}" ]] || return 0

  printf '%s idle_memory_high current=%s high=%s max=%s threshold=%s\n' \
    "$(timestamp)" "${current}" "${high:-unknown}" "${max:-unknown}" "${threshold}" >&2
  restart_service memory_high "${threshold}"
}

saw_busy=0
while :; do
  # If the service screen was intentionally stopped, let the watcher exit too.
  if command -v screen >/dev/null 2>&1 && ! screen -list 2>/dev/null | grep -qE "[0-9]+\.${SERVICE_SCREEN}[[:space:]]"; then
    exit 0
  fi
  if [[ "$(comfyui_pid_count)" == 1 ]]; then
    state="$(queue_state 2>/dev/null || printf 'unavailable')"
    if [[ "${state}" == "busy" ]]; then
      saw_busy=1
    elif [[ "${state}" == "empty" ]]; then
      if [[ "${RESTART_AFTER_EACH_TASK}" == "1" && "${saw_busy}" == "1" ]]; then
        saw_busy=0
        if ! restart_service task_completed >>"${WATCH_LOG}" 2>&1; then
          exit 1
        fi
      elif ! restart_if_idle_and_high >>"${WATCH_LOG}" 2>&1; then
        exit 1
      fi
    fi
  fi
  sleep "${INTERVAL_SECONDS}"
done
