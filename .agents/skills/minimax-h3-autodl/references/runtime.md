# Deployment runtime reference

## Local project

Project root:

```text
/Users/june2/code/github/minimax-h3-autodl
```

Read SSH connection values from the local `.env`. Require `.env` to be Git ignored and mode `0600`. Never print, log, upload, or commit its values.

## Verified deployment profile

```text
GPU: 1 × NVIDIA GeForce RTX 5090
ComfyUI: v0.30.0
PyTorch: 2.13.0+cu130
CUDA runtime: 13.0
model variant: MiniMax H3-Base FL2VA quantized consumer-GPU bundle
```

Use the data disk for models and caches; the system disk is too small for the model bundle.

## Remote layout

```text
data root: /root/autodl-tmp/h3
ComfyUI: /root/ComfyUI
model directory: /root/autodl-tmp/h3/comfyui-models
deployment scripts: /root/autodl-tmp/h3/deploy
logs: /root/autodl-tmp/h3/logs
cache: /root/autodl-tmp/h3/cache
temporary files: /root/autodl-tmp/h3/tmp
screen session: h3-comfyui
health endpoint: http://127.0.0.1:8188/system_stats
```

Initialize missing data directories without touching existing content:

```bash
mkdir -p /root/autodl-tmp/h3/{cache,comfyui-models,deploy,inputs,logs,outputs,tmp,workflows}
mkdir -p /root/autodl-tmp/h3/cache/{huggingface,pip,torch}
```

## Canonical project scripts

```text
scripts/remote/install-h3-comfyui.sh
scripts/remote/download-h3-comfy.sh
scripts/remote/verify-h3-models.sh
scripts/remote/start-h3-comfyui.sh
scripts/remote/validate-h3-deployment.sh
scripts/remote/run-h3-smoke.py
scripts/remote/extra_model_paths.yaml
scripts/capture-environment.sh
```

Upload remote scripts to task-neutral `.new` paths, validate them with `bash -n` or `python -m py_compile`, make them executable where appropriate, and atomically move them into `/root/autodl-tmp/h3/deploy/`. Do not replace a running service script during an active task.

## Required model files

Require these exact files:

```text
diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors
text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
vae/minimax_h3_video_vae_fp16.safetensors
vae/minimax_h3_audio_vae_fp32.safetensors
```

The pinned source revision, exact byte sizes, and SHA-256 values are recorded in `docs/01-deployment-steps.md` and enforced by `verify-h3-models.sh`. A successful downloader exit is not sufficient verification.

## Preflight

Run these checks before installation, validation, or restart:

```bash
nvidia-smi
free -h
df -h
df -Pk /root/autodl-tmp
pgrep -af 'ComfyUI/main.py|python main.py' || true
screen -ls || true
curl -fsS http://127.0.0.1:8188/system_stats || true
curl -fsS http://127.0.0.1:8188/queue || true
```

Require enough data-disk space for the model bundle and temporary downloads. Inspect an unhealthy existing process before restarting; never launch a second ComfyUI process over it.

## Start and validate the service

The starter is a foreground `exec` script. Launch it inside the persistent screen:

```bash
screen -dmS h3-comfyui bash -lc \
  'exec /root/autodl-tmp/h3/deploy/start-h3-comfyui.sh >> /root/autodl-tmp/h3/logs/comfyui-restart.log 2>&1'
```

After launch, require:

- exactly one matching ComfyUI process;
- a detached `h3-comfyui` screen;
- a successful `/system_stats` response;
- an empty queue;
- RTX 5090 and the pinned PyTorch/CUDA stack;
- the required H3 video and audio nodes;
- the `comfy-kitchen` CUDA backend available and enabled;
- model search paths pointing to the data disk.

Run `validate-h3-deployment.sh` after these checks. Run the minimal smoke test only after validation succeeds.

## Recovery and backup boundary

- An AutoDL environment image covers system-disk software but does not include data-disk model files.
- A recoverable deployment requires the environment image, the H3 data disk or its backup, and this repository's deployment files.
- After restoration, rerun model verification, health validation, restart validation, and one minimal audio/video smoke test.
- Never delete the model directory, `/root/ComfyUI`, shared deployment scripts, or user outputs while diagnosing deployment health.
