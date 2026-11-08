# DSH 接入详解与排错

本文假设你已经让 `http://127.0.0.1:8440/v1/models` 正常返回。

```bash
bash ~/bonsai/start-deepseek9b.sh status
# 期望输出：
#   7400 MiB, 557 MiB
#   :8440 online
#   PID 1236  RSS 1567MB
```

---

## 一、加 provider

DSH 的模型配置在 `~/.dsh/profiles/desktop/cordis.patch.yml`。

### 结构关键点

它**不是**新增一个顶层条目，而是在已有的 `llm-pi-ai` 条目的
`config.providers` 下面增加一个 provider。找到这段：

```yaml
- id: llm-pi-ai
  name: '@deepseek-ai/dsh-llm-pi-ai'
  config:
    providers:
      ollama:
        ...
      llamacpp:
        ...
      bonsai-wsl:
        ...
```

在 `providers:` 下面（与 `llamacpp` 等**同级**，6 个空格缩进）插入：

```yaml
      deepseek9b-local:
        displayName: DeepSeek 9B（本地·无审查·识图）
        api: openai-completions
        baseURL: http://127.0.0.1:8440/v1
        apiKeyEnv: DEEPSEEK9B_LOCAL_API_KEY
        compat:
          supportsDeveloperRole: false
        models:
          - id: deepseek9b
            name: DeepSeek-V4-Pro-Qwen3.5-9B｜无审查·识图·32K·38tok/s·需先启动WSL服务
            contextWindow: 32768
            maxTokens: 4096
            input:
              - text
              - image
```

字段说明：

| 字段 | 作用 | 注意 |
|---|---|---|
| `api` | 协议 | 本地 llama-server 用 `openai-completions` |
| `baseURL` | 端点 | 必须带 `/v1` |
| `apiKeyEnv` | **凭据引用名** | 不是密钥本身，见下一节 |
| `supportsDeveloperRole` | 是否支持 system role | 本地模型设 `false` |
| `contextWindow` | 上下文窗口 | 要和服务的 `-c` 值一致 |
| `maxTokens` | 单次输出上限 | **别设成和 contextWindow 一样大** |
| `input` | 模态 | 有 mmproj 才能写 `image` |

### 关于 `apiKeyEnv`

它是个**引用名**，DSH 会到 `~/.dsh/.credentials.yaml` 的 `refs:` 里找同名键：

```yaml
refs:
  LLAMACPP_API_KEY: llamacpp-local
  BONSAI_LOCAL_API_KEY: bonsai-local
  DEEPSEEK9B_LOCAL_API_KEY: deepseek9b-local    # ← 加这行
```

本地 llama-server **不校验 key**，所以值是任意占位符即可（保持和上面两个一致的风格）。

漏了这行的话，provider 会加载但请求时报凭据错误。

---

## 二、重启与验证

改完 `cordis.patch.yml` 后**必须重启 DSH**。注意：

```
DSH 主进程启动时间 < 配置修改时间  →  还在用旧配置
```

用 PowerShell 确认：

```powershell
Get-Process -Name 'DeepSeek Harness' | Select-Object Id, StartTime
(Get-Item "$env:USERPROFILE\.dsh\profiles\desktop\cordis.patch.yml").LastWriteTime
```

重启后模型选择器里应该出现「DeepSeek 9B（本地·无审查·识图）」。

### 不改 DSH 也能先验证配置是否会被正确加载

用 DSH 自己的 `loadProfile` + `composeEntries` 跑一遍（只读，不启动 Host）：

```javascript
// node verify-compose.cjs
const path = require('path');
const { pathToFileURL } = require('url');
const os = require('os');

const DSH = String.raw`<你的 DSH 安装目录>\resources\app\dsh`;
const bootPath = path.join(DSH, 'node_modules', '@deepseek-ai', 'dsh-app-boot', 'lib', 'index.js');

(async () => {
  const boot = await import(pathToFileURL(bootPath).href);
  const profile = boot.loadProfile('dsh', 'desktop',
      path.join(DSH, 'package.json'), path.join(os.homedir(), '.dsh'));
  const entries = boot.composeEntries([
    profile.layers.flatMap(l => l.patches), profile.patches
  ]);
  const llm = entries.find(e => e.id === 'llm-pi-ai');
  const providers = llm.config?.providers ?? {};
  console.log('providers:', Object.keys(providers).join(', '));
  console.log('deepseek9b-local:', JSON.stringify(providers['deepseek9b-local'], null, 2));
})();
```

看到 `deepseek9b-local` 且有正确 `baseURL` 就说明配置没问题。

---

## 三、排错表

### `Connection error`（TRANSPORT）

**最常见，9 成是服务没了。**

```bash
bash ~/bonsai/start-deepseek9b.sh status
```

如果显示 `offline`，说明 llama-server 进程已退出。原因通常是：

- 用 `wsl.exe -e bash -c "..."` 启动，命令返回后 WSL 回收了会话树
- 机器休眠 / WSL 被 `wsl --shutdown`

**修法**：用本项目的启动脚本（有 `setsid` + `disown` 三重脱离），或直接用 bat 双击。

长期方案：`daemon` 模式。

### `503 {"message":"Loading model"}`（SERVER）

这是 **llama-server 自己返回的**，说明网络是通的，只是模型在加载。

首次加载约 35 秒。DSH 的重试可能等不及。

**修法**：先手动 `status` 确认 online，再让 DSH 发请求。

### 请求成功但回复为空

看返回里的 `finish_reason`：

- `length` + `content: ""` + `reasoning_content` 很长 → **`max_tokens` 太小**，
  token 全花在思考上了。调到 1000 以上。
- `contextWindow` 超限 → 检查 `maxTokens` + 输入是否超过 `contextWindow`。

### 显存不足 / OOM

| 现象 | 修法 |
|---|---|
| 加载就失败 | 降 `-c` 或去掉 `-mm` |
| 跑几轮后崩 | 桌面程序抢显存，降到 16K 或关掉浏览器 |

显存实测见 README 的表格。

- 带视觉：只能用 32K
- 不带视觉：可以 48K

### `--parallel` 踩坑

如果手动改过 `--parallel 2`，会发现 `-c 32768` 变成每槽 16384。
DSH 请求超限就会失败。**保持 `--parallel 1`。**

---

## 四、回滚

```powershell
# 恢复 profile（改之前务必先备份）
Copy-Item "$env:USERPROFILE\.dsh\profiles\desktop\cordis.patch.yml.bak-before-deepseek9b-*" `
          "$env:USERPROFILE\.dsh\profiles\desktop\cordis.patch.yml" -Force

# 恢复凭据
Copy-Item "$env:USERPROFILE\.dsh\.credentials.yaml.bak-before-deepseek9b-*" `
          "$env:USERPROFILE\.dsh\.credentials.yaml" -Force
```

然后重启 DSH。

---

## 五、编辑 YAML 的两个硬规矩

1. **绝对不要写 UTF-8 BOM**。DSH 用 `JSON.parse`/YAML 解析直接读文件，
   BOM 会导致启动崩溃。用 Python 或 Node 写，别用 PowerShell 5.1 的
   `ConvertTo-Json | Set-Content`。

   自检：首字节应该是 `0x2d`（`-`，patch 文件是列表）或 `0x7b`（`{`，JSON）。

2. **YAML 锚点不能重复定义**。`&name` 只能定义一次，后面要用 `*name` 引用。
   重复定义会让严格解析器报 `found duplicate anchor`，虽然 DSH 可能容忍，
   但会给后续工具埋雷。
