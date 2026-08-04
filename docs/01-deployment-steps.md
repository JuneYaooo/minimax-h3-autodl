# MiniMax H3 AutoDL 部署步骤

本文覆盖首次安装、模型下载、启动、验收、镜像保存和恢复。

## 1. 目标配置

| 项目 | 当前值 |
| --- | --- |
| GPU | 1 × NVIDIA GeForce RTX 5090，32607 MiB |
| 主机内存 | 754 GiB |
| 系统盘 | 30 GiB |
| 数据盘 | `/root/autodl-tmp`，650 GiB |
| 推理前端 | ComfyUI v0.30.0 |
| ComfyUI commit | `b1693ecba9f5b65f8c80ab36b195ab963ec92413` |
| PyTorch | 2.13.0+cu130 |
| CUDA runtime | 13.0 |
| 模型路线 | Comfy-Org FL2VA 消费卡量化组合 |
| 本地能力 | T2VA、首帧/尾帧/首尾帧视频，原生立体声音频 |
| 本地分辨率边界 | H3-Base 约 768p；官方完整 2K 仍需托管的 Regenerate-2K |

## 2. 磁盘布局

| 内容 | 服务器路径 | 磁盘 | AutoDL 环境镜像是否包含 |
| --- | --- | --- | --- |
| ComfyUI | `/root/ComfyUI` | 系统盘 | 是 |
| Conda、PyTorch、CUDA Python 依赖 | `/root/miniconda3` | 系统盘/基础层 | 是 |
| H3 四个模型文件 | `/root/autodl-tmp/h3/comfyui-models` | 数据盘 | 否 |
| 缓存和临时文件 | `/root/autodl-tmp/h3/cache`、`tmp` | 数据盘 | 否 |
| 输入和输出 | `/root/autodl-tmp/h3/inputs`、`outputs` | 数据盘 | 否 |
| 工作流、部署脚本、日志 | `/root/autodl-tmp/h3/workflows`、`deploy`、`logs` | 数据盘 | 否；本项目另有副本 |

量化模型为 39.55 GiB，系统盘只有 30 GiB，因此模型必须在数据盘。可恢复的完整部署是：

```text
AutoDL 环境镜像
+ 原实例数据盘或数据盘备份
+ 本地项目中的脚本、清单和文档
```

只保存环境镜像不会保存模型。

## 3. 首次连接后的资源核验

先确认真实硬件和挂载，不要依据 AutoDL 登录横幅做容量判断：

```bash
nvidia-smi
free -h
df -h
python --version
python - <<'PY'
import torch
print("torch:", torch.__version__)
print("cuda runtime:", torch.version.cuda)
print("cuda available:", torch.cuda.is_available())
print("gpu:", torch.cuda.get_device_name(0) if torch.cuda.is_available() else None)
PY
```

验收条件：

- PyTorch 能识别 RTX 5090；
- 主机内存足够支撑 CPU offload；
- `/root/autodl-tmp` 是数据盘且空间充足；
- 不在 30 GiB 系统盘下载几十 GiB 模型；
- SSH 连接信息和密码只保存在本地、Git 忽略且权限为 `0600` 的 `.env`；不写入脚本、日志、版本库或正式报告。

## 4. 初始化数据盘目录

```bash
mkdir -p /root/autodl-tmp/h3/{cache,comfyui-models,deploy,inputs,logs,outputs,tmp,workflows}
mkdir -p /root/autodl-tmp/h3/cache/{huggingface,pip,torch}

export HF_HOME=/root/autodl-tmp/h3/cache/huggingface
export HUGGINGFACE_HUB_CACHE=/root/autodl-tmp/h3/cache/huggingface/hub
export PIP_CACHE_DIR=/root/autodl-tmp/h3/cache/pip
export TORCH_HOME=/root/autodl-tmp/h3/cache/torch
export TMPDIR=/root/autodl-tmp/h3/tmp
```

项目中的远程脚本位于 `scripts/remote/`。部署时应同步到：

```text
/root/autodl-tmp/h3/deploy/
```

## 5. 安装 ComfyUI 和依赖

固定使用已经验证的 ComfyUI v0.30.0，不在同一环境中混装未经验证的 SGLang、Torch 或 Transformers 版本。

项目脚本：

```text
scripts/remote/install-h3-comfyui.sh
scripts/remote/extra_model_paths.yaml
scripts/remote/start-h3-comfyui.sh
```

最终一致的核心版本：

```text
torch 2.13.0+cu130
torchvision 0.28.0+cu130
torchaudio 2.11.0+cu130
CUDA runtime 13.0
ComfyUI v0.30.0
```

Torch、Torchvision 和 Torchaudio 必须从同一 CUDA index 一起安装或升级，不能只升级其中一个。

## 6. 下载模型到数据盘

当前单卡路线只需要 FL2VA 四个量化文件，不需要下载约 134 GiB 的原始 BF16 FL2VA，也不需要下载 Ref2VA。

模型仓库：`Comfy-Org/MiniMax-H3`  
固定 revision：`fd70b39279d1ae6eb214c903f53e1bec3af19a77`

| 组件 | 文件 | 字节数 | SHA-256 |
| --- | --- | ---: | --- |
| Transformer | `diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors` | 20,970,379,616 | `e889202c41dafb67b10d67b97f0d8541508036a6090af23425a5c2615d03c47a` |
| Text Encoder | `text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors` | 15,687,142,551 | `35a88d51044231fe332301d7a62aa81e3f2cba62febeb446e2c1e3e0ef76f2c6` |
| Video VAE | `vae/minimax_h3_video_vae_fp16.safetensors` | 5,207,808,496 | `7c1f131492e7eddacaac9069a61b81bdd39de5cc96561e677c5eab1cdce5e522` |
| Audio VAE | `vae/minimax_h3_audio_vae_fp32.safetensors` | 605,254,808 | `8e505d95dd1561d47abd43d4238fd40d9bb1ae9e147ed0a4cba778d76ae4db48` |
| 合计 | — | 42,470,585,471 bytes | 四项都必须通过 |

推荐直接使用：

```text
scripts/remote/download-h3-comfy.sh
scripts/remote/verify-h3-models.sh
```

下载脚本支持通过 AutoDL 学术代理从官方 `huggingface.co` 获取文件，并使用单文件顺序 Range 续传。下载完成后关闭代理：

```bash
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
```

验收不看下载器是否打印“成功”，只认精确字节数、safetensors 头和 SHA-256。

## 7. 启动和健康检查

```bash
screen -dmS h3-comfyui bash -lc \
  'exec /root/autodl-tmp/h3/deploy/start-h3-comfyui.sh \
  > /root/autodl-tmp/h3/logs/comfyui.log 2>&1'
```

检查：

```bash
curl -fsS http://127.0.0.1:8188/system_stats | python -m json.tool
screen -ls
tail -100 /root/autodl-tmp/h3/logs/comfyui.log
```

健康状态应同时满足：

- `/system_stats` 返回成功；
- 能识别 RTX 5090 和 PyTorch cu130；
- `MiniMaxH3ImageToVideo`、`VAEDecodeAudio`、`CreateVideo`、`SaveVideo` 节点存在；
- `comfy-kitchen` CUDA backend 为 available，且没有被禁用；
- 模型搜索路径指向数据盘。

## 8. Web UI 的安全访问

优先使用 SSH 隧道，不把 ComfyUI 裸露到公网：

```bash
ssh -N \
  -L 8188:127.0.0.1:8188 \
  -p <SSH端口> \
  root@<AutoDL连接地址>
```

本地浏览器打开：

```text
http://127.0.0.1:8188
```

## 9. 最小冒烟验收

工作流中的四个 loader 应对应：

```text
diffusion model: minimax_h3_fl2va_pruned_int8_convrot.safetensors
text encoder: qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
video VAE: minimax_h3_video_vae_fp16.safetensors
audio VAE: minimax_h3_audio_vae_fp32.safetensors
```

只运行短时长、低分辨率、低步数请求，以验证模型加载、采样、视频 VAE、音频 VAE 和 MP4 保存链路。冒烟媒体只保存在本机或服务器，不纳入版本库。

部署验收脚本：

```text
scripts/remote/run-h3-smoke.py
scripts/remote/validate-h3-deployment.sh
```

当前 H3 ComfyUI 节点要求帧数满足：

```text
frames = 17 × n + 5
```

冒烟请求也必须使用合法帧数，不能在推理请求中填写任意帧数。

## 10. 服务停止和重启

正常停止：

```bash
screen -S h3-comfyui -X stuff $'\003'
```

确认旧进程退出后才能再次启动：

```bash
pgrep -af 'ComfyUI/main.py|python main.py'
```

## 11. 保存环境镜像和数据备份

保存前：

1. 等待生成任务结束；
2. 正常停止 ComfyUI；
3. 执行 `sync`；
4. 运行 `scripts/capture-environment.sh`；
5. 检查系统盘和数据盘；
6. 在 AutoDL 保存环境镜像；
7. 单独备份 `/root/autodl-tmp/h3`；
8. 不要因为镜像保存成功就释放原数据盘。

建议镜像名：

```text
minimax-h3-comfyui-v0.30.0-rtx5090-cu130-working
```

恢复后必须重新执行：

```bash
/root/autodl-tmp/h3/deploy/verify-h3-models.sh
curl -fsS http://127.0.0.1:8188/system_stats
```

并执行一次最小音视频冒烟测试。只有镜像能启动、但找不到数据盘模型，不算恢复成功。

## 12. 官方资料

- MiniMax H3：<https://huggingface.co/MiniMaxAI/MiniMax-H3>
- MiniMax H3 Community License：<https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/LICENSE>
- AutoDL 基础配置：<https://www.autodl.com/docs/base_config/>
- AutoDL Hugging Face 学术加速：<https://hf-mirror.com/>

当前开放权重只覆盖 H3-Base。H3-Context-IR 和 H3-Regenerate-2K 没有随本地权重开放，不能把本部署描述为完全离线的官方 2K 工作流。
