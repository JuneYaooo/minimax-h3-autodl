# H3 内存高水位运维

这份参考只处理主机内存/cgroup，不把磁盘文件占用、GPU 显存和进程 RSS 混为一谈。

## 先判定是不是进程缓存

在远端运行 `scripts/remote/check-h3-memory.sh`，保存输出到任务专属日志。至少记录：

- ComfyUI 唯一 PID、`VmRSS`/`VmHWM`；
- cgroup `memory.current`、`memory.high`、`memory.max`、`memory.events`；
- `memory.stat` 的 `anon`/`file`；
- `/proc/$PID/smaps_rollup` 的 `Anonymous`、`RssAnon`、`RssFile`；
- `/queue` 的 running/pending 数量。

判断规则：

| 观察 | 结论 | 动作 |
| --- | --- | --- |
| 重启后 RSS 回到低位，任务后升高并形成平台 | 模型 CPU offload/allocator 缓存，未证明有泄漏 | 采用任务后回收和计划重启 |
| 同一 graph 每跑一次都继续增长，冷重启后恢复 | 进程内 retained state；可能是缓存，也可能是节点引用 | 保留最小复现，减少分支/参考输入并做插件诊断 |
| `memory.stat anon`/`RssAnon` 高 | 活的 tensor、权重或 Python 对象 | 缩短任务、减少参考输入、切换模型族时重启 |
| `memory.stat file` 高而 anon 较低 | mmap 权重/文件页缓存 | 不删除模型；只有在空闲时做常规回收，不把它当作根因 |
| `memory.events high` 增加 | cgroup 正在回收/限速 | 停止提交下一任务，空队列后重启 |

如果冷重启后 baseline 仍然异常高，先查第二个 Python/ComfyUI 进程、共享内存和容器内
其他服务；不要直接把它归因于单个 graph 泄漏。

不要用删除 Hugging Face/Torch cache、删除 safetensors、`drop_caches` 或单独
`torch.cuda.empty_cache()` 作为 CPU RSS 的修复。它们不会释放仍被 ComfyUI 引用的
CPU tensor；删除模型文件还会破坏部署。

## 安全阈值和任务策略

默认部署启用 `RESTART_AFTER_EACH_TASK=1`：watcher 看到队列从 busy 变为空后，调用一次
计划重启。因此像 69.6 GiB RSS、73.8 GiB cgroup 这种“尚未越线，但下一个 243 帧任务
风险偏高”的状态也会被清掉。若明确接受更高吞吐和保留缓存，可设置
`RESTART_AFTER_EACH_TASK=0`，此时只在下面的动态阈值触发重启。

启用 watcher 后，批处理 manifest 的 `restart_comfyui_every_tasks` 应设为 `0`，不要让
两个重启 supervisor 互相叠加；只有在关闭 watcher 时才使用 runner 自己的定期重启。

阈值必须从当前 cgroup 读取，不要硬编码宿主机总内存。默认采用较低者：

```text
restart_threshold = min(85% × memory.max, 92% × memory.high)
```

若 `memory.max` 或 `memory.high` 为 `max`/不可读，则以 `memory.current` 的趋势和
`memory.events high` 为依据，不能声称有精确阈值。

在本项目已观测的约 96.6 GiB max、92.3 GiB high 配额下，长 Ref2VA 任务建议在
80–85 GiB 处停止继续排队；243 帧任务完成后，队列为空就重启。任何重启前必须：

1. 查询 `/queue`，确认 running 和 pending 都为 0；
2. 保留任务状态 JSON、日志和输出文件；
3. 使用 `restart-h3-comfyui.sh`，等待健康检查通过；
4. 再提交下一任务。

当前进程已接近 `memory.high` 时，不要通过加大 `--reserve-vram` 来“保内存”；这通常
会增加 CPU offload。降低 reserve 可能引发 GPU OOM，只能做受控 A/B 测试。

## 降低单任务峰值

- 单 GPU 严格串行，不并发生成；
- 长任务优先拆成合法帧数（例如 `124 + 124`，最后再裁剪/拼接）；
- 参考图缩放到目标尺寸附近，先用 1 张主图；
- 参考视频/音频先裁成必要时长，避免把整段素材重复编码；
- graph 内不要保留不再使用的多路参考、预览和 latent 分支；
- FL2VA 与 Ref2VA 分批运行，模型族切换后重启一次；
- 不要为了清理 CPU RSS 盲目启用 `--lowvram`、`--novram` 或未验证的缓存开关。

## 何时升级实例

如果正式工作流必须保留当前 243 帧、多参考和高分辨率设置，96 GiB 级 cgroup 没有
足够余量。优先把容器配额提高到至少 128 GiB，复杂批次使用 192 GiB 或更高；宿主机
`free -h` 显示的总内存不能替代 cgroup 配额检查。
