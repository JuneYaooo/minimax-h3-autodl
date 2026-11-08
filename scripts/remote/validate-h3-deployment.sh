#!/usr/bin/env bash
set -Eeuo pipefail

DATA_ROOT="${DATA_ROOT:-/root/autodl-tmp/h3}"
MODEL_ROOT="${MODEL_ROOT:-${DATA_ROOT}/comfyui-models}"
MODEL_PATHS_CONFIG="${MODEL_PATHS_CONFIG:-${DATA_ROOT}/deploy/extra_model_paths.yaml}"
DOWNLOAD_SCREEN="${DOWNLOAD_SCREEN:-h3-curl-download-turbo}"
SERVICE_SCREEN="${SERVICE_SCREEN:-h3-comfyui}"
MEMORY_WATCH_ENABLED="${MEMORY_WATCH_ENABLED:-1}"
MEMORY_WATCH_SCREEN="${MEMORY_WATCH_SCREEN:-h3-memory-watch}"
VERIFY_SCRIPT="${VERIFY_SCRIPT:-${DATA_ROOT}/deploy/verify-h3-models.sh}"
CHECK_SERVICE_SCRIPT="${CHECK_SERVICE_SCRIPT:-${DATA_ROOT}/deploy/check-h3-service.py}"
CHECK_MEDIA_SCRIPT="${CHECK_MEDIA_SCRIPT:-${DATA_ROOT}/deploy/check-h3-media.py}"
SMOKE_SCRIPT="${SMOKE_SCRIPT:-${DATA_ROOT}/deploy/run-h3-smoke.py}"
REF2VA_SMOKE_SCRIPT="${REF2VA_SMOKE_SCRIPT:-${DATA_ROOT}/deploy/run-h3-ref2va-smoke.py}"
PYTHON_BIN="${PYTHON_BIN:-/root/miniconda3/bin/python}"
EXPECTED_COMFYUI="${EXPECTED_COMFYUI:-0.30.0}"
EXPECTED_PYTORCH="${EXPECTED_PYTORCH:-2.13.0+cu130}"
EXPECTED_DEVICE="${EXPECTED_DEVICE:-NVIDIA GeForce RTX 5090}"
SERVICE_LOG="${SERVICE_LOG:-}"
RUN_FL2VA_SMOKE="${RUN_FL2VA_SMOKE:-1}"
RUN_REF2VA_SMOKE="${RUN_REF2VA_SMOKE:-0}"
REF2VA_PROMPT_FILE="${REF2VA_PROMPT_FILE:-}"
REF2VA_REFERENCES_FILE="${REF2VA_REFERENCES_FILE:-}"
REF2VA_OUTPUT_PREFIX="${REF2VA_OUTPUT_PREFIX:-h3-validation/ref2va/minimax_h3}"

LOG_ROOT="${DATA_ROOT}/logs"
OUTPUT_ROOT="${DATA_ROOT}/outputs"
STATUS_LOG="${LOG_ROOT}/h3-validation-status.txt"
CHECKSUM_LOG="${LOG_ROOT}/model-checksum.log"
PREFLIGHT_LOG="${LOG_ROOT}/h3-service-preflight.json"
FL2VA_LOG="${LOG_ROOT}/h3-smoke.log"
FL2VA_RESOURCE_LOG="${LOG_ROOT}/h3-smoke-resources.log"
FL2VA_FFPROBE_LOG="${LOG_ROOT}/h3-smoke-ffprobe.json"
REF2VA_LOG="${LOG_ROOT}/h3-ref2va-smoke.log"
REF2VA_RESOURCE_LOG="${LOG_ROOT}/h3-ref2va-smoke-resources.log"
REF2VA_FFPROBE_LOG="${LOG_ROOT}/h3-ref2va-smoke-ffprobe.json"

mkdir -p "${LOG_ROOT}" "${OUTPUT_ROOT}" "${DATA_ROOT}/tmp"
: >"${STATUS_LOG}"

record_status() {
  printf '%s\n' "$*" | tee -a "${STATUS_LOG}"
}

ACTIVE_MONITOR_PID=""
cleanup_active_monitor() {
  if [[ -n "${ACTIVE_MONITOR_PID}" ]]; then
    kill "${ACTIVE_MONITOR_PID}" 2>/dev/null || true
    wait "${ACTIVE_MONITOR_PID}" 2>/dev/null || true
    ACTIVE_MONITOR_PID=""
  fi
}
trap cleanup_active_monitor EXIT

fail_validation() {
  local stage="$1" message="$2"
  record_status "validation_end=$(date -Is) epoch=$(date +%s) rc=1 stage=${stage} error=${message}"
  exit 1
}

require_boolean_flag() {
  local name="$1" value="$2"
  if [[ "${value}" != "0" && "${value}" != "1" ]]; then
    fail_validation configuration "${name}_must_be_0_or_1"
  fi
}

require_boolean_flag RUN_FL2VA_SMOKE "${RUN_FL2VA_SMOKE}"
require_boolean_flag RUN_REF2VA_SMOKE "${RUN_REF2VA_SMOKE}"
require_boolean_flag MEMORY_WATCH_ENABLED "${MEMORY_WATCH_ENABLED}"

for required in \
  "${PYTHON_BIN}" "${VERIFY_SCRIPT}" "${CHECK_SERVICE_SCRIPT}" "${CHECK_MEDIA_SCRIPT}" \
  "${MODEL_PATHS_CONFIG}"; do
  if [[ ! -e "${required}" ]]; then
    fail_validation configuration "required_path_missing:${required}"
  fi
done
if [[ ! -x "${PYTHON_BIN}" ]]; then
  fail_validation configuration "python_not_executable:${PYTHON_BIN}"
fi
for command_name in awk ffmpeg ffprobe find grep nvidia-smi pgrep screen; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    fail_validation configuration "required_command_missing:${command_name}"
  fi
done
if ! grep -Fq "base_path: ${MODEL_ROOT}" "${MODEL_PATHS_CONFIG}"; then
  fail_validation configuration "model_search_path_mismatch:${MODEL_ROOT}"
fi
if [[ "${RUN_FL2VA_SMOKE}" == "1" && ! -f "${SMOKE_SCRIPT}" ]]; then
  fail_validation configuration "fl2va_smoke_script_missing:${SMOKE_SCRIPT}"
fi
if [[ "${RUN_REF2VA_SMOKE}" == "1" ]]; then
  if [[ ! -f "${REF2VA_SMOKE_SCRIPT}" ]]; then
    fail_validation configuration "ref2va_smoke_script_missing:${REF2VA_SMOKE_SCRIPT}"
  fi
  if [[ -z "${REF2VA_PROMPT_FILE}" || ! -f "${REF2VA_PROMPT_FILE}" ]]; then
    fail_validation configuration "ref2va_prompt_file_missing"
  fi
  if [[ -z "${REF2VA_REFERENCES_FILE}" || ! -f "${REF2VA_REFERENCES_FILE}" ]]; then
    fail_validation configuration "ref2va_references_file_missing"
  fi
fi

stage_start_epoch="$(date +%s)"
record_status "validation_start=$(date -Is) epoch=${stage_start_epoch} download_screen=${DOWNLOAD_SCREEN}"

while screen -list 2>/dev/null | grep -q "\.${DOWNLOAD_SCREEN}[[:space:]]"; do
  sleep 20
done
record_status "download_screen_finished=$(date -Is) epoch=$(date +%s)"

mapfile -t comfyui_pids < <(
  pgrep -f 'python([0-9.]*)? .*main\.py .*--listen' 2>/dev/null || true
)
if (( ${#comfyui_pids[@]} != 1 )); then
  fail_validation process "expected_one_comfyui_process:count=${#comfyui_pids[@]}"
fi
record_status "comfyui_process_ok=$(date -Is) count=1"

if ! screen -list 2>/dev/null | grep -qE "[0-9]+\.${SERVICE_SCREEN}[[:space:]]"; then
  fail_validation screen "screen_session_missing:${SERVICE_SCREEN}"
fi
record_status "comfyui_screen_ok=$(date -Is) screen=${SERVICE_SCREEN}"
if [[ "${MEMORY_WATCH_ENABLED}" == "1" ]] \
  && ! screen -list 2>/dev/null | grep -qE "[0-9]+\.${MEMORY_WATCH_SCREEN}[[:space:]]"; then
  fail_validation screen "memory_watch_screen_missing:${MEMORY_WATCH_SCREEN}"
fi
if [[ "${MEMORY_WATCH_ENABLED}" == "1" ]]; then
  record_status "memory_watch_screen_ok=$(date -Is) screen=${MEMORY_WATCH_SCREEN}"
fi

checksum_start_epoch="$(date +%s)"
record_status "checksum_start=$(date -Is) epoch=${checksum_start_epoch}"
set +e
MODEL_ROOT="${MODEL_ROOT}" "${VERIFY_SCRIPT}" >"${CHECKSUM_LOG}" 2>&1
checksum_rc=$?
set -e
checksum_end_epoch="$(date +%s)"
record_status "checksum_end=$(date -Is) epoch=${checksum_end_epoch} rc=${checksum_rc} duration_seconds=$((checksum_end_epoch-checksum_start_epoch))"
if (( checksum_rc != 0 )); then
  fail_validation checksum "model_verification_failed:rc=${checksum_rc}"
fi

run_service_preflight() {
  "${PYTHON_BIN}" "${CHECK_SERVICE_SCRIPT}" \
    --expected-comfyui "${EXPECTED_COMFYUI}" \
    --expected-pytorch "${EXPECTED_PYTORCH}" \
    --expected-device "${EXPECTED_DEVICE}" \
    --summary-record "${PREFLIGHT_LOG}"
}

if ! run_service_preflight >>"${STATUS_LOG}" 2>&1; then
  fail_validation service_preflight "health_queue_node_or_model_check_failed"
fi
record_status "service_preflight_ok=$(date -Is) epoch=$(date +%s)"

if [[ -n "${SERVICE_LOG}" ]]; then
  latest_service_log="${SERVICE_LOG}"
else
  latest_service_log="$({
    find "${LOG_ROOT}" -maxdepth 1 -type f \
      \( -name 'comfyui.log' -o -name 'comfyui-restart.log' \) \
      -printf '%T@ %p\n' 2>/dev/null || true
  } | sort -nr | head -1 | cut -d' ' -f2-)"
fi
if [[ -z "${latest_service_log}" || ! -f "${latest_service_log}" ]]; then
  fail_validation cuda_backend "comfyui_service_log_missing"
fi
backend_line="$(grep -F 'Found comfy_kitchen backend cuda:' "${latest_service_log}" | tail -1 || true)"
if [[ "${backend_line}" != *"'available': True"* || "${backend_line}" != *"'disabled': False"* ]]; then
  fail_validation cuda_backend "comfy_kitchen_cuda_not_available_and_enabled"
fi
record_status "cuda_backend_ok=$(date -Is) backend=comfy_kitchen_cuda"

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

run_smoke() {
  local label="$1" generation_log="$2" resource_log="$3" ffprobe_log="$4"
  shift 4
  local marker="${DATA_ROOT}/tmp/h3-${label}-start.marker"
  local generation_start_epoch generation_end_epoch generation_rc
  local output_file peak_gpu_mib peak_ram_kib volume_log max_volume

  : >"${resource_log}"
  touch "${marker}"
  monitor_resources >>"${resource_log}" 2>&1 &
  ACTIVE_MONITOR_PID=$!
  generation_start_epoch="$(date +%s)"
  record_status "generation_start=$(date -Is) epoch=${generation_start_epoch} mode=${label}"

  set +e
  "$@" >"${generation_log}" 2>&1
  generation_rc=$?
  set -e
  cleanup_active_monitor

  generation_end_epoch="$(date +%s)"
  record_status "generation_end=$(date -Is) epoch=${generation_end_epoch} mode=${label} rc=${generation_rc} duration_seconds=$((generation_end_epoch-generation_start_epoch))"
  if (( generation_rc != 0 )); then
    fail_validation "${label}_generation" "smoke_failed:rc=${generation_rc}"
  fi

  output_file="$({
    find "${OUTPUT_ROOT}" -type f -name '*.mp4' -newer "${marker}" -printf '%T@ %p\n' 2>/dev/null || true
  } | sort -nr | head -1 | cut -d' ' -f2-)"
  if [[ -z "${output_file}" || ! -s "${output_file}" ]]; then
    fail_validation "${label}_output" "new_nonempty_mp4_not_found"
  fi

  if ! ffprobe -v error \
    -show_entries \
format=filename,size,duration:stream=index,codec_type,codec_name,width,height,r_frame_rate,avg_frame_rate,sample_rate,channels,channel_layout \
    -of json "${output_file}" >"${ffprobe_log}"; then
    fail_validation "${label}_media" "ffprobe_failed"
  fi
  if ! "${PYTHON_BIN}" "${CHECK_MEDIA_SCRIPT}" "${ffprobe_log}" >>"${STATUS_LOG}" 2>&1; then
    fail_validation "${label}_media" "audio_video_contract_failed"
  fi

  volume_log="${ffprobe_log%.json}-volumedetect.txt"
  if ! ffmpeg -hide_banner -nostats -i "${output_file}" -map 0:a:0 \
    -af volumedetect -f null - >"${volume_log}" 2>&1; then
    fail_validation "${label}_media" "audio_decode_or_volume_check_failed"
  fi
  max_volume="$(awk '/max_volume:/ { value=$(NF-1) } END { print value }' "${volume_log}")"
  if [[ -z "${max_volume}" || "${max_volume}" == "-inf" ]]; then
    fail_validation "${label}_media" "audio_is_silent_or_volume_unreadable"
  fi

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
    ' "${resource_log}"
  )
  record_status "resource_peaks mode=${label} peak_gpu_mib=${peak_gpu_mib} peak_ram_kib=${peak_ram_kib}"

  if ! run_service_preflight >>"${STATUS_LOG}" 2>&1; then
    fail_validation "${label}_postflight" "queue_or_service_unhealthy_after_smoke"
  fi
  record_status "generation_acceptance_ok=$(date -Is) mode=${label} max_volume_db=${max_volume} ffprobe_log=${ffprobe_log}"
}

if [[ "${RUN_FL2VA_SMOKE}" == "1" ]]; then
  run_smoke \
    fl2va "${FL2VA_LOG}" "${FL2VA_RESOURCE_LOG}" "${FL2VA_FFPROBE_LOG}" \
    "${PYTHON_BIN}" -u "${SMOKE_SCRIPT}"
else
  record_status "generation_skipped=$(date -Is) mode=fl2va"
fi

if [[ "${RUN_REF2VA_SMOKE}" == "1" ]]; then
  run_smoke \
    ref2va "${REF2VA_LOG}" "${REF2VA_RESOURCE_LOG}" "${REF2VA_FFPROBE_LOG}" \
    "${PYTHON_BIN}" -u "${REF2VA_SMOKE_SCRIPT}" \
    --prompt-file "${REF2VA_PROMPT_FILE}" \
    --references-file "${REF2VA_REFERENCES_FILE}" \
    --filename-prefix "${REF2VA_OUTPUT_PREFIX}" \
    --record "${LOG_ROOT}/h3-ref2va-smoke-request.json" \
    --result-record "${LOG_ROOT}/h3-ref2va-smoke-result.json"
else
  record_status "generation_skipped=$(date -Is) mode=ref2va"
fi

record_status "validation_end=$(date -Is) epoch=$(date +%s) rc=0 duration_seconds=$(($(date +%s)-stage_start_epoch))"
