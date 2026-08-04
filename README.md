# MiniMax H3 AutoDL

这是一个在 AutoDL 单张 RTX 5090（`nvidia-smi` 可用显存 32,607 MiB）上部署、
验证和恢复 MiniMax H3-Base 的项目。目前同时部署 FL2VA 和 Ref2VA，覆盖文生音视频、
首尾帧约束以及图片、视频、音频混合参考。

## 先说结论：不是官方 BF16“满血版”

本项目不是 `MiniMaxAI/MiniMax-H3` 发布的原始 BF16 checkpoint，也不是 MiniMax
线上产品的完整三模块系统。当前使用的是 `Comfy-Org/MiniMax-H3` 提供的消费卡量化组合：

```text
仓库：Comfy-Org/MiniMax-H3
revision：fd70b39279d1ae6eb214c903f53e1bec3af19a77
模型：H3-Base FL2VA + H3-Base Ref2VA
运行框架：ComfyUI
```

实际模型清单如下。下载后的验收不是看命令是否成功，而是要求五个文件的路径、
精确字节数、safetensors 文件头和 SHA-256 全部匹配。

| 组件 | 权重文件 | 当前精度/格式 | 大小 |
| --- | --- | --- | ---: |
| FL2VA Transformer | `minimax_h3_fl2va_pruned_int8_convrot.safetensors` | Pruned INT8 / ConvRot | 20,970,379,616 bytes |
| Ref2VA Transformer | `minimax_h3_ref2va_pruned_int8_convrot.safetensors` | Pruned INT8 / ConvRot | 20,970,379,616 bytes |
| Qwen3-VL 32B Text Encoder | `qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors` | NVFP4 / AWQ | 15,687,142,551 bytes |
| Video VAE | `minimax_h3_video_vae_fp16.safetensors` | FP16 | 5,207,808,496 bytes |
| Audio VAE | `minimax_h3_audio_vae_fp32.safetensors` | FP32 | 605,254,808 bytes |
| 合计 | 5 个文件 | 单卡消费级量化组合 | 63,440,965,087 bytes（约 59.08 GiB） |

因此，准确的对外描述是：

> MiniMax H3-Base FL2VA + Ref2VA 的 ComfyUI 单卡量化部署。

不应描述成“MiniMax H3 官方原始 BF16 满血版”“官方完整离线版”或“官方完整 2K
工作流”。这里的“非满血”具体指 Transformer 和文本编码器已经量化、Transformer
为推理裁剪版本，并且官方线上系统的两个模块没有开放本地权重；它不代表生成效果
只剩下某个固定比例。

## 官方完整系统与本地部署的边界

MiniMax 描述的完整 H3 系统包含三个模块：

1. `H3-Context-IR`：托管的多阶段提示理解与编排系统；
2. `H3-Base`：本地可部署的 768p 音视频生成基础模型；
3. `H3-Regenerate-2K`：将 Base 结果结合原始上下文重新生成到 2K 的托管模块。

本项目只在本地运行第 2 项，但同时包含它的两个任务族：

- `H3-Base-FL2VA`：文本、首帧、尾帧、首帧+尾帧；
- `H3-Base-Ref2VA`：图片、视频、音频以及它们的混合参考。

`H3-Context-IR` 和 `H3-Regenerate-2K` 没有包含在开放权重中，完整官方 2K 链路仍需
MiniMax API。本地直接生成 2048×1152 只能算显存容量探测，不能等同于官方
Regenerate-2K 的质量或工作流。

## 已实测能力矩阵

下表是 2026-08-04（服务器 UTC+08:00）在当前实例上的真实端到端结果。技术通过要求
使用正确 checkpoint、完成 conditioning 和采样、解码出 H.264 视频与 32 kHz
双声道 AAC，并且任务结束后队列回空；涉及参考语义的项目还做了抽帧视觉复核。

| 模型/模式 | 测试输入 | 测试规格 | 结果 | 复核结论 |
| --- | --- | --- | --- | --- |
| FL2VA 文生音视频（T2VA） | 文本 | 608×352，56 帧，5 步 | 已通过 | 部署回归通过，视频和非静音立体声音轨正常 |
| FL2VA 首帧 | 1 张首帧图 | 608×352，56 帧，5 步 | 已通过 | 输出第一帧的主体、场景和构图明显受输入约束 |
| FL2VA 尾帧 | 1 张尾帧图 | 608×352，56 帧，5 步 | 已通过 | 输出最后一帧与条件图视觉一致，SSIM 约 0.78 |
| FL2VA 首帧+尾帧 | 2 张端点图 | 608×352，56 帧，5 步 | 已通过 | 两端约束同时生效 |
| Ref2VA 单图 | 人物与厨房参考图 | 608×352，56 帧，5 步 | 已通过 | 人物、服装、厨房和摄影风格均保留 |
| Ref2VA 多图 | 人物图 + 黏土森林图 | 608×352，56 帧，5 步 | 已通过 | 人物线索与第二张图的材质、场景风格成功融合 |
| Ref2VA 纯视频 | 5 秒双人厨房动作视频 | 608×352，56 帧，5 步 | 已通过 | 人物、机位、泡沫互动与动作时序明显受视频约束 |
| Ref2VA 视频+配套音轨 | 同一视频及其 AAC 音轨 | 608×352，56 帧，5 步 | 已通过 | 视频和配套音频 conditioning 均被节点接受，输出音轨非静音 |
| Ref2VA 图片+独立音频 | 人物图 + 5 秒 WAV 音乐 | 608×352，56 帧，5 步 | 已通过 | 图片、独立音频路径均打通，输出音轨非静音 |
| Ref2VA 图片+视频动作替换 | 白衣人物图 + 5 秒厨房动作视频 | 608×352，124 帧，8 步 | 已通过 | 黄衣人物被白衣人物替换；抛泡沫、俯身洗碗等动作顺序保留 |
| Ref2VA 抖音舞蹈动作替换 | 成年白衣人物图 + 用户指定舞蹈视频和原曲 | 576×1024，124 帧，8 步 | 已通过 | 原舞者身份被替换；约 5/6 关键动作按顺序出现，单人和镜中反射关系正确 |
| Ref2VA 拟人猪猪+抖音动作+原曲（旧版） | Zeakai `gpt-image-2-pro` 生成的淡紫小裙子拟人猪图 + 5 秒舞蹈视频和原曲 | 576×1024，124 帧，10 步 | 技术链路通过，角色验收未通过 | 单主体、镜中反射、动作顺序和原曲均已验证；但角色是“猪头+人形身体/手脚”，不符合“真实猪身、四只猪蹄”的最终造型要求，不能作为最终交付 |
| FL2VA 纯文本小猪穿裙子跳舞 | 仅文本描述；不使用角色图、动作视频或原曲 | 576×1024，124 帧，10 步 | 已通过 | 小猪保持桶状猪身、四条猪腿和四只分趾猪蹄，无人手、人腿或鞋；原生电子舞曲和猪蹄踏地声正常 |
| FL2VA 纯文本小猪穿裙子跳舞（15 秒） | 仅文本描述；不使用角色图、动作视频或原曲 | 576×1024，362 帧，10 步 | 已通过 | 15.08 秒逐秒检查中角色、裙子和四只猪蹄稳定；动作和原生立体声电子舞曲连续 |

以上短规格项目主要用于能力验收，不代表正式出片质量。当前实例另有 1344×768、
124–362 帧、20 步的长视频实测记录。

旧版拟人猪猪案例的本地视频、技术 QA、动作对照、合规审核和 manifest 位于
`output/h3-pig-dance/release/20260804_zeakai_dress_h3/`。它证明了多参动作和音频链路可用，
但角色形态没有通过用户验收，已被标记为待替换版本，不能作为最终交付。此外，参考舞蹈、
原曲和源视频授权仍待核验，公开发布前还应增加 AI 生成标识；因此它也不是无需复审即可
上传抖音的发布清稿。当前通过验收的纯文本 15 秒版本位于
`output/h3-pig-dance/release/20260804_text_only_true_pig_h3_15s/`；它没有使用上述抖音
参考素材，但公开发布时仍需声明 AI 生成内容。

## 是否支持动作模仿

支持，但应准确称为“生成式动作参考/动作模仿”，不是严格的骨骼驱动、逐帧动作捕捉
或 Pose ControlNet。

Ref2VA 可以从参考视频中学习并复现：

- 动作的大致顺序、节奏和关键姿态；
- 人物与物体的互动关系；
- 镜头构图、运镜和场景布局；
- 配套音轨的节奏或音色信息；
- 使用另一张人物/角色图进行生成式角色替换。

本次“白衣人物图 + 厨房动作视频”测试中，参考和输出都按 2 FPS 抽帧比对：输出保留了
前半段抛泡沫、后半段回到水槽洗碗的时序，同时将参考视频中的黄衣人物换成白衣人物。
这证明动作参考有效，但局部手势、面部、衣物、背景和时间点仍会由模型重新生成，不能
承诺逐帧一一对应。舞蹈、武术或产品动作若要求严格复刻，仍应逐个关键动作节点验收。

用户指定的抖音舞蹈也已用成年白衣人物做代理实测：宽站姿、侧倾甩头、曲臂外展、
双臂上举和收束等约 5/6 个关键节点按顺序出现，镜面中只有一个主体的正确反射，
但动作相对参考存在约 0.5 秒级偏移。这个结果验证了舞蹈素材、原曲和竖屏多参管线；
旧版拟人猪猪测试使用 Zeakai `GptImage2ProTool` 生成的全身图完成：淡紫小裙子和白鞋
全程稳定，镜面中只有一个主体的正确反射，约 5/6 动作节点按顺序出现；输出原曲相对
参考的最佳对齐偏移约 12 ms，近似归一化相关度约 0.93。但该输入角色含人形身体、手、
腿和鞋，只能作为链路验证，不能据此声称“真实猪形态穿裙子跳舞”已经通过。新版必须保持
桶状猪身、四条短猪腿和四只分趾猪蹄，再重新完成视觉和动作验收。

官方规格允许最多 9 张图片、3 段视频、3 段音频，混合参考文件总数最多 12 个；
单段视频/音频推荐 2–15 秒。音频不能作为唯一输入，必须伴随至少一张图片或一段视频。
本项目已验证主要输入类别和混合路径，没有为了冒烟测试机械地填满 9/3/3 的数量上限。

## 32 GB 显存是否跑满

结论是：**空闲时没有跑满，推理时会使用 95% 左右，复杂参考或长视频时接近跑满；
不应并发生成。**

ComfyUI 使用 dynamic VRAM loading，并通过 `--reserve-vram 2` 尝试给系统保留 2 GiB。
服务刚启动且队列为空时的一次只读快照为 8,032 MiB；完成猪猪 Ref2VA 测试后，队列虽然
已经为空，缓存仍使显存暂时保持在 25,352 MiB（约 77.7%）。两次 GPU 利用率都是 0%，
都不属于正在推理。加载模型并推理后的峰值如下：

| 场景 | 参数 | 峰值显存 | 占 32,607 MiB |
| --- | --- | ---: | ---: |
| T2VA 部署回归 | 608×352，56 帧，5 步 | 30,890 MiB | 约 94.7% |
| Ref2VA 单图 | 608×352，56 帧，5 步 | 31,112 MiB | 约 95.4% |
| Ref2VA 视频 | 608×352，56 帧，5 步 | 31,592 MiB | 约 96.9% |
| Ref2VA 多图 | 608×352，56 帧，5 步 | 31,624 MiB | 约 97.0% |
| Ref2VA 图片+视频动作替换 | 608×352，124 帧，8 步 | 31,656 MiB | 约 97.1% |
| Ref2VA 抖音竖屏舞蹈替换 | 576×1024，124 帧，8 步 | 31,592 MiB | 约 96.9% |
| Ref2VA 猪猪小裙子舞蹈 | 576×1024，124 帧，10 步 | 31,496 MiB | 约 96.6% |
| FL2VA 纯文本小猪穿裙子跳舞 | 576×1024，124 帧，10 步 | 30,730 MiB | 约 94.2% |
| FL2VA 纯文本小猪穿裙子跳舞（15 秒） | 576×1024，362 帧，10 步 | 30,602 MiB | 约 93.9% |
| FL2VA 标准质量档 | 1344×768，124 帧，20 步 | 29,822 MiB | 约 91.5% |
| FL2VA 约 13–15 秒正式案例 | 1344×768，311–362 帧，20 步 | 32,094 MiB | 约 98.4% |
| 本地 2K 容量探测 | 2048×1152，124 帧，1 步 | 32,094 MiB | 约 98.4% |

显存峰值不会随分辨率和步数简单单调增加，因为模型动态装载、引用 token 数、帧数、
缓存状态以及 CPU/GPU 交换都会影响采样结果。31–32 GiB 已经是实际意义上的“吃满”，
只是在空闲状态释放了大部分工作显存。

## 项目入口

- Skill：[`.agents/skills/minimax-h3-autodl/SKILL.md`](.agents/skills/minimax-h3-autodl/SKILL.md)
- 完整部署步骤：[`docs/01-deployment-steps.md`](docs/01-deployment-steps.md)
- 踩坑与恢复经验：[`docs/02-pitfalls-and-lessons.md`](docs/02-pitfalls-and-lessons.md)
- 时长、性能和成本实测：[`docs/04-duration-cost-estimates.md`](docs/04-duration-cost-estimates.md)
- FL2VA 测试 runner：[`scripts/remote/run-h3-smoke.py`](scripts/remote/run-h3-smoke.py)
- Ref2VA 测试 runner：[`scripts/remote/run-h3-ref2va-smoke.py`](scripts/remote/run-h3-ref2va-smoke.py)
- 只读服务预检：[`scripts/remote/check-h3-service.py`](scripts/remote/check-h3-service.py)
- 音视频技术验收：[`scripts/remote/check-h3-media.py`](scripts/remote/check-h3-media.py)
- 安全重启与重启后验收：[`scripts/remote/restart-h3-comfyui.sh`](scripts/remote/restart-h3-comfyui.sh)
- 下载脚本：[`scripts/remote/download-h3-comfy.sh`](scripts/remote/download-h3-comfy.sh)
- 模型校验脚本：[`scripts/remote/verify-h3-models.sh`](scripts/remote/verify-h3-models.sh)
- 本地测试：[`tests/test_h3_scripts.py`](tests/test_h3_scripts.py)

本地回归测试：

```bash
python -m unittest discover -s tests -v
```

GitHub Actions 会同时运行单元测试、Python 语法检查和所有 shell 脚本的 `bash -n` 检查。

模型文件必须放在 `/root/autodl-tmp` 数据盘；AutoDL 环境镜像不会包含数据盘中的权重、
输入和输出。测试媒体、抖音参考素材、权重、私有日志和本地 artifacts 均不进入版本库。
