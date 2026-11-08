# 在 8GB 显卡上跑 9B 模型并接入 DeepSeek Harness

> 一个把 **DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic**（Q4_K_M，5.24 GiB）
> 做成 DSH 本地模型 provider 的最小可复现方案。
> 全部参数都在 RTX 4060 Laptop（8GB）+ WSL2 Ubuntu 上实测过。

[![GPU](https://img.shields.io/badge/VRAM-8GB%20tested-76b900?style=flat-square)]()
[![Model](https://img.shields.io/badge/model-Q4__K__M%205.24%20GiB-4c1d95?style=flat-square)]()
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

---

## 这个模型是什么

| 项 | 值 |
|---|---|
| 底座 | Qwen3.5-9B |
| 蒸馏来源 | DeepSeek-V4-Pro（Max Effect 模式） |
| 训练数据 | 约 25 万条数学 / STEM 样本，SFT + RL |
| 去审查 | [Heretic](https://heretic-project.org) v2.0.0.dev0，ARA 消融 |
| 拒答率 | **3/100**（原版 100/100），KL 散度 0.0422 |
| 架构 | `qwen35`，32 层，n_embd 4096，16 Q heads / 4 KV heads |
| 原生上下文 | 262,144（训练值，8GB 卡上跑不到） |
| 许可 | Apache-2.0 |

上游仓库：
- 权重（BF16，18.9 GB）：[`xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic`](https://huggingface.co/xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic)
- GGUF 量化（本项目用的）：[`Sakura721/...-GGUF`](https://huggingface.co/Sakura721/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic-GGUF)

> **注意**：网传「5.6G 就能跑」指的是社区 GGUF 量化版，不是那个 18.9 GB 的官方仓库。
> 别下错。

---

## 实测数据

所有数字都是本机跑出来的（RTX 4060 Laptop 8188 MiB，llama.cpp build 10743 / commit adfffbe41）。

### 显存与上下文

| 模式 | 上下文 | 显存占用 | 余量 | 可行 |
|---|---:|---:|---:|:--:|
| 纯文本 | 16,384 | 6656 MiB | 1301 MiB | ✅ |
| 纯文本 | 32,768 | 6544 MiB | 1413 MiB | ✅ |
| 纯文本 | 49,152 | 6768 MiB | 1189 MiB | ✅ 推荐(无视觉) |
| **视觉** | **32,768** | **7449 MiB** | **508 MiB** | ✅ **本项目默认** |
| 视觉 | 49,152 | — | — | ❌ 显存不够 |

`mmproj`（视觉投影）本身约占 0.9 GB。所以**要识图就只能 32K，要 48K 就得放弃识图**。

### 推理速度

| 项目 | 数值 |
|---|---|
| 生成速度 | **37~39 tok/s** |
| prompt 处理（带 252 token tools 定义） | 1102 tok/s |
| 首次加载 | 约 35 秒 |
| 数学正确性 | `17 × 23 = 391` ✅ |
| 识图正确性 | 正确识别「白底 + 红色实心圆」 ✅ |

---

## 三个必须知道的坑

### 1. `--parallel N` 会切分上下文

```
--parallel 2 会让 -c 32768 变成每槽 16384
```

DSH 默认 `maxTokens = 32768`，槽位一小就判定超限。
**本项目固定 `--parallel 1`。**

### 2. 进程会被 WSL 回收

`wsl.exe -e bash -c "..."` 这种调用返回后，WSL 会回收整个会话树。
你测着一切正常，命令一结束服务就没了 —— 表现就是 DSH 报 `Connection error`。

必须三重脱离：

```bash
setsid nohup bash -c "exec llama-server ..." & 
disown
```

本项目还提供 `daemon` 子命令，每 5 秒探活、掉线自动重拉。

### 3. `maxTokens` 不能设太大

模型 `contextWindow = 32768`，如果 `maxTokens` 也设 32768，输入+输出必然超限。
本项目设 **4096**，给输入留 28K 空间。

---

## 快速开始

### 前置条件

- WSL2 + Ubuntu
- 一块 ≥8GB 显存的 NVIDIA 显卡
- 一个能用的 llama.cpp 构建（本项目用 build 10743，更早的版本没测过）
- Python 3（下载脚本用）

### 1. 下载模型

```bash
# 需要代理时加 --proxy
python scripts/download-model.py --with-mmproj --mirror hf-mirror --no-proxy

# 或走本地代理（国内推荐）
python scripts/download-model.py --with-mmproj --proxy http://127.0.0.1:65532
```

脚本会分块并行下载、断点续传，最后校验 SHA256：

| 文件 | 大小 | SHA256 |
|---|---:|---|
| Q4_K_M.gguf | 5,629,111,968 | `82a19e2f...66dadab` |
| mmproj-f16.gguf | 918,167,360 | `f8d09a6d...690a5e` |

### 2. 启动服务

```bash
# 复制到 WSL 里
cp scripts/start-deepseek9b.sh ~/bonsai/
chmod +x ~/bonsai/start-deepseek9b.sh

# 如果模型不在默认位置（~/models/...），用 MODEL_DIR 指定
MODEL_DIR=/mnt/c/Users/you/.dsh/models/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic \
  bash ~/bonsai/start-deepseek9b.sh start 32768

# 默认位置直接启动
bash ~/bonsai/start-deepseek9b.sh start 32768

# 或守护模式（推荐，掉线自动重拉）
bash ~/bonsai/start-deepseek9b.sh daemon 32768
```

脚本会先做预检：找不到 `llama-server` 或模型会**明确报错并中止**，
不会留下一半启动的进程。

验证：

```bash
bash ~/bonsai/start-deepseek9b.sh status
bash ~/bonsai/start-deepseek9b.sh test
```

Windows 用户也可以直接双击 `scripts/启动DeepSeek-9B.bat`。

### 3. 接入 DSH

把 [`dsh/provider-snippet.yml`](dsh/provider-snippet.yml) 里的段追加到
`~/.dsh/profiles/desktop/cordis.patch.yml` 的 `llm-pi-ai → providers` 下面。

再在 `~/.dsh/.credentials.yaml` 的 `refs:` 下加：

```yaml
  DEEPSEEK9B_LOCAL_API_KEY: deepseek9b-local
```

**重启 DSH**，模型选择器里就会出现「DeepSeek 9B（本地·无审查·识图）」。

详细步骤和排错见 [`docs/dsh-setup.md`](docs/dsh-setup.md)。

---

## 环境变量覆盖

`start-deepseek9b.sh` 全部路径都可覆盖，方便换机器：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `MODEL_DIR` | `~/models/DeepSeek-...-heretic` | 模型目录 |
| `MODEL` | `$MODEL_DIR/...-Q4_K_M.gguf` | 主模型 |
| `MMPROJ` | `$MODEL_DIR/mmproj-...-f16.gguf` | 视觉投影 |
| `LLAMA_DIR` | `~/bonsai/llama-prism-b10743-adfffbe` | llama.cpp 目录 |
| `NV` | `~/miniconda3/envs/.../nvidia` | CUDA 库路径 |
| `PORT` | `8440` | 服务端口 |
| `ALIAS` | `deepseek9b` | 模型别名 |

例子：

```bash
MODEL_DIR=/data/models PORT=9000 bash scripts/start-deepseek9b.sh start 49152
```

---

## 目录结构

```
.
├── README.md
├── LICENSE
├── .gitignore
├── scripts/
│   ├── download-model.py          # 分块下载 + SHA256 校验
│   ├── start-deepseek9b.sh        # 启动/守护/停止/状态/测试
│   └── 启动DeepSeek-9B.bat         # Windows 双击启动
├── dsh/
│   └── provider-snippet.yml       # DSH provider 配置片段
└── docs/
    └── dsh-setup.md               # DSH 接入与排错详解
```

---

## 已知限制

- **只在 8GB 笔记本显卡上验证过**，更大显存的卡可以开更高上下文，但没测。
- **llama.cpp 版本敏感**。量化作者标注需要 b12182，本机 b10743 实测能正常加载推理，
  但更早的版本可能不认 `qwen35` 架构。
- **思考链会吃掉 token**。`max_tokens` 设太小（比如 40）会出现 `content` 为空、
  `reasoning_content` 塞满的情况。这是模型行为，不是 bug。
- **单槽位并发**。`--parallel 1` 意味着同时只能处理一个请求，DSH 并发调用会排队。

---

## 许可

本项目代码 MIT。模型权重遵循 Apache-2.0（见上游仓库）。

模型为社区微调版本，请自行评估使用场景与合规性。
