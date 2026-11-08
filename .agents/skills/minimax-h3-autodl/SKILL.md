---
name: minimax-h3-autodl
description: "Deploy, validate, start, recover, and maintain MiniMax H3-Base FL2VA and Ref2VA on this project's AutoDL instance, including cgroup/CPU-RAM high-water diagnosis, safe task-batch restarts, model-family switching, and resource-aware Ref2VA operation. Use when Codex needs to deploy or audit H3, download or verify exact model files, install the pinned ComfyUI/PyTorch/CUDA stack, start or recover the service, run FL2VA/Ref2VA smoke tests, diagnose memory.high or RSS growth, or optimize long-running generation batches. Chinese triggers include 部署 H3、安装 H3、下载模型、校验模型、启动 ComfyUI、恢复实例、部署验收、冒烟测试、内存高水位、内存暴涨、CPU offload、ComfyUI 缓存 and 长批次优化."
---

# Deploy MiniMax H3 on AutoDL

Use the project's validated deployment scripts and exact model inventory. Read [references/runtime.md](references/runtime.md) completely before connecting. Read [references/memory-operations.md](references/memory-operations.md) for any CPU-RAM, RSS, cgroup, long-batch, or high-watermark question. Read `docs/01-deployment-steps.md` before a first installation or instance rebuild.

## Protect credentials and existing data

- Read connection values from the local `.env`. Require mode `0600` and Git ignore coverage.
- Prefer SSH key or agent authentication. Send `H3_SSH_PASSWORD` only to an interactive prompt through tool-side TTY orchestration; never print it, place it in command arguments, or persist it in scripts or logs.
- Do not reinstall, overwrite, or delete a healthy deployment merely because a deployment command was requested. Inspect the current state first.
- Never delete `/root/ComfyUI`, the model directory, the shared deployment scripts, or user outputs during deployment maintenance.
- Do not expose ComfyUI publicly. Use an SSH tunnel for browser access.
- Treat cgroup memory as the operational limit. Host `free -h` is not a substitute for `memory.max`/`memory.high`.
- Do not call a high RSS value a disk-cache problem without checking `memory.stat`, `smaps_rollup`, and `memory.events`.
- Never restart or kill ComfyUI while `/queue` has a running or pending task. Preserve task state and outputs before a planned restart.

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
5. Run `download-h3-comfy.sh` to download the five exact FL2VA/Ref2VA model files to the data disk.
6. Run `verify-h3-models.sh`. Require exact paths, byte sizes, safetensors headers, and SHA-256 values.
7. Start ComfyUI in the persistent `h3-comfyui` screen with `start-h3-comfyui.sh`.
8. Run `validate-h3-deployment.sh`, then execute the FL2VA and representative Ref2VA smoke tests only after health and model checks pass.
9. Run `scripts/capture-environment.sh` after acceptance and keep the resulting snapshot local.

Do not describe the deployment as complete until health, required nodes, CUDA backend, all five model files, restart recovery, FL2VA audio/video, and representative Ref2VA image/video/audio paths have passed. Keep hosted H3-Context-IR and H3-Regenerate-2K outside the local acceptance claim.

## Operate long jobs without crossing the memory high watermark

1. Before a long task or batch, run the read-only `check-h3-memory.sh` snapshot and record the unique ComfyUI PID, cgroup limits, queue state, and current RSS.
2. Submit exactly one generation at a time on the single GPU. Do not infer that an empty GPU means the process has released CPU offload or allocator memory.
3. After each 124-frame-or-longer Ref2VA task, wait for the queue to become empty, verify the output and checkpoint JSON, then take another memory snapshot.
4. If `memory.events` reports new `high` events, or `memory.current` is at/above the lower of 85% of `memory.max` and 92% of `memory.high`, stop submitting work. When the queue is empty, use `restart-h3-comfyui.sh` and revalidate before continuing.
5. Restart when switching between FL2VA and Ref2VA model families. Do not keep two ComfyUI processes to avoid a restart; they compete for the same GPU and memory budget.
6. For 243-frame or multi-reference jobs, prefer legal chunks such as `124 + 124` when continuity permits, and reduce reference resolution/count/duration before changing allocator flags.
7. If RSS grows monotonically for the same graph but returns to a low baseline after a cold restart, classify it as retained process state; distinguish expected cache/offload from a node/plugin leak with a minimal reproduction. If the cold baseline does not recover, inspect other processes and shared memory before attributing it to ComfyUI.

The starter enables the idle-only `watch-h3-memory.sh` guard by default. With
`RESTART_AFTER_EACH_TASK=1`, it observes a busy-to-empty queue transition and performs one planned
restart after every task; the cgroup threshold remains a fallback for retained state that was
already present before the watcher observed a task. It refuses to act while `/queue` has running
or pending work and uses lightweight post-restart health validation. Keep
`MEMORY_WATCH_ENABLED=0` only for controlled diagnostics or when an external task supervisor owns
restarts. When the watcher is enabled, set batch manifests' `restart_comfyui_every_tasks` to `0`
to avoid two restart supervisors. Never replace it with `drop_caches` or an unconditional timer.

The full classification table, cgroup v1/v2 notes, and threshold rationale are in [references/memory-operations.md](references/memory-operations.md). The memory snapshot is read-only; it must not be used as an implicit restart command.

## Validate or recover an existing deployment

1. Inspect `/system_stats`, the queue, `screen -ls`, matching processes, recent service logs, disk space, and the exact model paths.
2. If a healthy unique ComfyUI process exists, do not start another one.
3. If unhealthy, inspect the process and logs before restarting. Restart only when no task is active.
4. For a planned restart of a healthy, empty service, use `restart-h3-comfyui.sh`; it preserves the single-process/screen boundary and runs validation after recovery.
5. After an instance restore or model read error, rerun `verify-h3-models.sh` before the smoke test.
6. Require exactly one ComfyUI process, the `h3-comfyui` screen, a healthy endpoint, an empty queue, and successful validation after restart.

## Keep deployment smoke artifacts local

Use short, low-cost smoke requests only to prove model loading, conditioning, sampling, video VAE, audio VAE, and MP4 saving. For FL2VA, distinguish T2VA, first-frame, last-frame, and first-and-last-frame evidence. For Ref2VA, record the actual checkpoint and reference modalities; a successful `MiniMaxH3ReferenceToVideo` graph using the FL2VA checkpoint is not Ref2VA acceptance. Do not treat smoke media as a retained creative output, upload it to GitHub, or call it a production-quality result.

## Hand off

Report the deployment mode, actual versions, health result, model verification result, smoke-test result, restart/recovery result, unresolved risks, and backup boundary. Never include credentials, private host values, raw environment snapshots, generated media, or local-only project records.
