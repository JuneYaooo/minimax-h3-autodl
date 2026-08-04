---
name: minimax-h3-autodl
description: "Deploy, validate, start, recover, and maintain MiniMax H3-Base FL2VA on this project's AutoDL instance. Use when Codex needs to perform or audit a first-time H3 deployment, download and verify the exact model files, install the validated ComfyUI and PyTorch/CUDA stack, start or recover the service, run deployment health checks or a minimal smoke test, capture the environment, or diagnose deployment failures. Chinese triggers include 部署 H3、安装 H3、下载模型、校验模型、启动 ComfyUI、恢复实例、部署验收 and 冒烟测试."
---

# Deploy MiniMax H3 on AutoDL

Use the project's validated deployment scripts and exact model inventory. Read [references/runtime.md](references/runtime.md) completely before connecting. Read `docs/01-deployment-steps.md` before a first installation or instance rebuild.

## Protect credentials and existing data

- Read connection values from the local `.env`. Require mode `0600` and Git ignore coverage.
- Prefer SSH key or agent authentication. Send `H3_SSH_PASSWORD` only to an interactive prompt through tool-side TTY orchestration; never print it, place it in command arguments, or persist it in scripts or logs.
- Do not reinstall, overwrite, or delete a healthy deployment merely because a deployment command was requested. Inspect the current state first.
- Never delete `/root/ComfyUI`, the model directory, the shared deployment scripts, or user outputs during deployment maintenance.
- Do not expose ComfyUI publicly. Use an SSH tunnel for browser access.

## Determine the deployment mode

Classify the request before changing the server:

1. **First deployment**: ComfyUI, the H3 data root, or required model files are absent.
2. **Validation**: the deployment exists and needs health, version, model, or smoke verification.
3. **Recovery**: the service or restored instance is unhealthy, while files may still be intact.

For validation or recovery, preserve the current installation and diagnose before installing anything.

## Perform a first deployment

1. Verify the real GPU, RAM, system disk, and `/root/autodl-tmp` data disk. Do not trust only the login banner.
2. Create the H3 data and cache layout documented in the runtime reference.
3. Upload the canonical files from `scripts/remote/` to `/root/autodl-tmp/h3/deploy/`.
4. Run `install-h3-comfyui.sh` to install the pinned ComfyUI and consistent PyTorch/CUDA packages.
5. Run `download-h3-comfy.sh` to download the four exact FL2VA model files to the data disk.
6. Run `verify-h3-models.sh`. Require exact paths, byte sizes, safetensors headers, and SHA-256 values.
7. Start ComfyUI in the persistent `h3-comfyui` screen with `start-h3-comfyui.sh`.
8. Run `validate-h3-deployment.sh`, then execute the minimal smoke test only after health and model checks pass.
9. Run `scripts/capture-environment.sh` after acceptance and keep the resulting snapshot local.

Do not describe the deployment as complete until health, required nodes, CUDA backend, all four model files, restart recovery, and a minimal audio/video smoke path have passed.

## Validate or recover an existing deployment

1. Inspect `/system_stats`, the queue, `screen -ls`, matching processes, recent service logs, disk space, and the exact model paths.
2. If a healthy unique ComfyUI process exists, do not start another one.
3. If unhealthy, inspect the process and logs before restarting. Restart only when no task is active.
4. After an instance restore or model read error, rerun `verify-h3-models.sh` before the smoke test.
5. Require exactly one ComfyUI process, the `h3-comfyui` screen, a healthy endpoint, an empty queue, and successful validation after restart.

## Keep deployment smoke artifacts local

Use a short, low-cost smoke request only to prove model loading, sampling, video VAE, audio VAE, and MP4 saving. Do not treat smoke media as a retained creative output, upload it to GitHub, or call it a production-quality result.

## Hand off

Report the deployment mode, actual versions, health result, model verification result, smoke-test result, restart/recovery result, unresolved risks, and backup boundary. Never include credentials, private host values, raw environment snapshots, generated media, or local-only project records.
