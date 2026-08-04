#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/root/autodl-tmp/h3}"
DOWNLOAD_SCREEN="${DOWNLOAD_SCREEN:-h3-curl-download-turbo}"
VERIFY_SCRIPT="${VERIFY_SCRIPT:-${DATA_ROOT}/deploy/verify-h3-models.sh}"
SMOKE_SCRIPT="${SMOKE_SCRIPT:-${DATA_ROOT}/deploy/run-h3-smoke.py}"
LOG_ROOT="${DATA_ROOT}/logs"
OUTPUT_ROOT="${DATA_ROOT}/outputs"
STATUS_LOG="${LOG_ROOT}/h3-validation-status.txt"
CHECKSUM_LOG="${LOG_ROOT}/model-checksum.log"
SMOKE_LOG="${LOG_ROOT}/h3-smoke.log"
RESOURCE_LOG="${LOG_ROOT}/h3-smoke-resources.log"
FFPROBE_LOG="${LOG_ROOT}/h3-smoke-ffprobe.json"
MARKER="${DATA_ROOT}/tmp/h3-smoke-start.marker"

mkdir -p "${LOG_ROOT}" "${OUTPUT_ROOT}" "${DATA_ROOT}/tmp"

record_status() {
  printf '%s\n' "$*" | tee -a "${STATUS_LOG}"
}

stage_start_epoch="$(date +%s)"
record_status "validation_wait_start=$(date -Is) epoch=${stage_start_epoch} download_screen=${DOWNLOAD_SCREEN}"

while screen -list 2>/dev/null | grep -q "\.${DOWNLOAD_SCREEN}[[:space:]]"; do
  sleep 20
done

record_status "download_screen_finished=$(date -Is) epoch=$(date +%s)"

checksum_start_epoch="$(date +%s)"
record_status "checksum_start=$(date -Is) epoch=${checksum_start_epoch}"
set +e
"${VERIFY_SCRIPT}" >"${CHECKSUM_LOG}" 2>&1
checksum_rc=$?
set -e
checksum_end_epoch="$(date +%s)"
record_status "checksum_end=$(date -Is) epoch=${checksum_end_epoch} rc=${checksum_rc} duration_seconds=$((checksum_end_epoch-checksum_start_epoch))"
if (( checksum_rc != 0 )); then
  record_status "validation_end=$(date -Is) epoch=$(date +%s) rc=${checksum_rc} stage=checksum"
  exit "${checksum_rc}"
fi

curl -fsS http://127.0.0.1:8188/system_stats >/dev/null
record_status "comfyui_health_ok=$(date -Is) epoch=$(date +%s)"

: >"${RESOURCE_LOG}"
touch "${MARKER}"

monitor_resources() {
  while true; do
    now_iso="$(date -Is)"
    now_epoch="$(date +%s)"
    read -r gpu_mib gpu_util < <(
      nvidia-smi \
        --query-gpu=memory.used,utilization.gpu \
        --format=csv,noheader,nounits | tr -d ','
    )
    read -r mem_total_kib mem_available_kib < <(
      awk '
        /MemTotal:/ { total=$2 }
        /MemAvailable:/ { available=$2 }
        END { print total, available }
      ' /proc/meminfo
    )
    printf 'iso=%s epoch=%s gpu_mib=%s gpu_util_pct=%s ram_used_kib=%s ram_available_kib=%s\n' \
      "${now_iso}" "${now_epoch}" "${gpu_mib}" "${gpu_util}" \
      "$((mem_total_kib-mem_available_kib))" "${mem_available_kib}"
    sleep 2
  done
}

monitor_resources >>"${RESOURCE_LOG}" 2>&1 &
monitor_pid=$!
cleanup_monitor() {
  kill "${monitor_pid}" 2>/dev/null || true
  wait "${monitor_pid}" 2>/dev/null || true
}
trap cleanup_monitor EXIT

generation_start_epoch="$(date +%s)"
record_status "generation_start=$(date -Is) epoch=${generation_start_epoch} width=608 height=352 frames=56 steps=5 fps=24"
set +e
python -u "${SMOKE_SCRIPT}" >"${SMOKE_LOG}" 2>&1
generation_rc=$?
set -e
generation_end_epoch="$(date +%s)"
cleanup_monitor
trap - EXIT
record_status "generation_end=$(date -Is) epoch=${generation_end_epoch} rc=${generation_rc} duration_seconds=$((generation_end_epoch-generation_start_epoch))"

if (( generation_rc != 0 )); then
  record_status "validation_end=$(date -Is) epoch=$(date +%s) rc=${generation_rc} stage=generation"
  exit "${generation_rc}"
fi

output_file="$({
  find "${OUTPUT_ROOT}" -type f -name '*.mp4' -newer "${MARKER}" -printf '%T@ %p\n' 2>/dev/null || true
} | sort -nr | head -1 | cut -d' ' -f2-)"

if [[ -z "${output_file}" || ! -s "${output_file}" ]]; then
  record_status "validation_end=$(date -Is) epoch=$(date +%s) rc=1 stage=output_lookup"
  exit 1
fi

ffprobe -v error \
  -show_entries \
format=filename,size,duration:stream=index,codec_type,codec_name,width,height,r_frame_rate,avg_frame_rate,sample_rate,channels,channel_layout \
  -of json "${output_file}" >"${FFPROBE_LOG}"

read -r peak_gpu_mib peak_ram_kib < <(
  awk '
    {
      gpu=ram=""
      for (i=1; i<=NF; i++) {
        if ($i ~ /^gpu_mib=/) { split($i, a, "="); gpu=a[2]+0 }
        if ($i ~ /^ram_used_kib=/) { split($i, a, "="); ram=a[2]+0 }
      }
      if (gpu > max_gpu) max_gpu=gpu
      if (ram > max_ram) max_ram=ram
    }
    END { print max_gpu+0, max_ram+0 }
  ' "${RESOURCE_LOG}"
)

record_status "output_file=${output_file}"
record_status "resource_peaks peak_gpu_mib=${peak_gpu_mib} peak_ram_kib=${peak_ram_kib}"
record_status "ffprobe_log=${FFPROBE_LOG}"
record_status "validation_end=$(date -Is) epoch=$(date +%s) rc=0 duration_seconds=$(($(date +%s)-stage_start_epoch))"
