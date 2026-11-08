#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only H3/ComfyUI memory and cgroup snapshot. It never restarts services,
# deletes files, or changes allocator settings.

COMFYUI_URL="${COMFYUI_URL:-http://127.0.0.1:8188}"
CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"

pids=()
while IFS= read -r pid; do
  [[ -n "${pid}" ]] && pids+=("${pid}")
done < <(pgrep -f 'python([0-9.]*)? .*main\.py .*--listen' 2>/dev/null || true)
printf 'timestamp=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'comfyui_pid_count=%s\n' "${#pids[@]}"
if (( ${#pids[@]} == 1 )); then
  pid="${pids[0]}"
  printf 'comfyui_pid=%s\n' "${pid}"
  awk '/VmRSS:|VmHWM:|VmSize:|RssAnon:|RssFile:/ {print "process_" tolower($1) "=" $2 " " $3}' \
    "/proc/${pid}/status" 2>/dev/null || true
  if [[ -r "/proc/${pid}/smaps_rollup" ]]; then
    awk '/^(Rss|Pss|Private_Clean|Private_Dirty|Anonymous|Swap):/ {print "smaps_" tolower($1) "=" $2 " " $3}' \
      "/proc/${pid}/smaps_rollup" 2>/dev/null || true
  fi
fi

if [[ -r "${CGROUP_ROOT}/memory.current" ]]; then
  # cgroup v2
  printf 'cgroup_version=2\n'
  for key in memory.current memory.high memory.max memory.events memory.stat; do
    if [[ -r "${CGROUP_ROOT}/${key}" ]]; then
      sed 's/^/cgroup_/' "${CGROUP_ROOT}/${key}"
    fi
  done
elif [[ -r "${CGROUP_ROOT}/memory/memory_usage_in_bytes" ]]; then
  # cgroup v1 fallback
  printf 'cgroup_version=1\n'
  for key in memory_usage_in_bytes memory.soft_limit_in_bytes memory.limit_in_bytes memory.failcnt; do
    if [[ -r "${CGROUP_ROOT}/memory/${key}" ]]; then
      printf 'cgroup_%s=%s\n' "${key}" "$(<"${CGROUP_ROOT}/memory/${key}")"
    fi
  done
  if [[ -r "${CGROUP_ROOT}/memory/memory.stat" ]]; then
    sed 's/^/cgroup_/' "${CGROUP_ROOT}/memory/memory.stat"
  fi
else
  printf 'cgroup_version=unknown\n'
fi

if command -v curl >/dev/null 2>&1; then
  curl -fsS --max-time 5 "${COMFYUI_URL}/queue" 2>/dev/null \
    | tr -d '\n' | sed 's/^/queue_json=/' || printf 'queue_json=unavailable\n'
  printf '\n'
fi
