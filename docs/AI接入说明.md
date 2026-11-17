# AI 纠错接入说明

## 一、支持哪些厂商

`data/ai-providers.json` 内置 16 个预设，设置页按 **国内 / 海外** 分组：

| 分组 | 厂商 | 协议 | 默认模型 | 默认 Base URL |
|---|---|---|---|---|
| 国内 | DeepSeek | openai | `deepseek-chat` | `https://api.deepseek.com/v1` |
| 国内 | Kimi（月之暗面） | openai | `moonshot-v1-32k` | `https://api.moonshot.cn/v1` |
| 国内 | 智谱 GLM | openai | `glm-4-flash` | `https://open.bigmodel.cn/api/paas/v4` |
| 国内 | 通义千问（百炼） | openai | `qwen-plus` | `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| 国内 | 豆包（火山方舟） | openai | `doubao-seed-1-6-250615` | `https://ark.cn-beijing.volces.com/api/v3` |
| 国内 | MiMo（小米） | openai | `mimo-7b-rl` | 见下 |
| 国内 | 腾讯混元 | openai | `hunyuan-turbos-latest` | `https://api.hunyuan.cloud.tencent.com/v1` |
| 国内 | MiniMax | openai | `abab6.5s-chat` | `https://api.minimax.chat/v1` |
| 国内 | Ollama（本地） | openai | `qwen2.5:7b` | `http://127.0.0.1:11434/v1` |
| 国内 | 自定义（OpenAI 兼容） | openai | —— | 自填 |
| 海外 | OpenAI | openai | `gpt-4o-mini` | `https://api.openai.com/v1` |
| 海外 | Anthropic Claude | anthropic | `claude-haiku-4-5` | `https://api.anthropic.com/v1` |
| 海外 | Google Gemini | gemini | `gemini-2.5-flash` | `https://generativelanguage.googleapis.com/v1beta` |
| 海外 | xAI Grok | openai | `grok-4-fast` | `https://api.x.ai/v1` |
| 海外 | Mistral | openai | `mistral-small-latest` | `https://api.mistral.ai/v1` |
| 海外 | OpenRouter | openai | `deepseek/deepseek-chat` | `https://openrouter.ai/api/v1` |

**MiMo 注意**：小米对外还没给稳定公开的 OpenAI 兼容端点，`data/ai-providers.json` 里填的是占位值。
设置页的 Base URL 可以直接改，改成官方文档给的那个即可，不用改代码。

## 二、三种协议怎么发

`lib/fanhuo/ai_proofread.dart` 的 `buildRequest()` 一个函数分三路：

### OpenAI 兼容（14 个厂商共用）

```
POST {baseUrl}/chat/completions
Authorization: Bearer {key}
{"model": "...", "temperature": 0.1, "max_tokens": 4096,
 "messages": [{"role":"system","content":"..."},{"role":"user","content":"..."}]}
```

### Anthropic

```
POST {baseUrl}/messages
x-api-key: {key}
anthropic-version: 2023-06-01
{"model": "...", "max_tokens": 4096, "temperature": 0.1,
 "system": "...", "messages": [{"role":"user","content":[{"type":"text","text":"..."}]}]}
```

注意 Anthropic 的 `system` 是顶层字段，不是 messages 里的一条。

### Gemini

```
POST {baseUrl}/models/{model}:generateContent?key={key}
{"systemInstruction": {"parts":[{"text":"..."}]},
 "contents": [{"role":"user","parts":[{"text":"..."}]}],
 "generationConfig": {"temperature": 0.1, "maxOutputTokens": 4096}}
```

注意 Gemini 的 key 在 URL 查询参数里，所以**日志绝对不能打完整 URL**，
`AiRequest.path` 字段就是专门给日志用的（只有 `openai` / `anthropic` / `gemini` 三个字符串）。

## 三、纠错是怎么做的（需求五）

### 3.1 提示词的四条硬规则

`ProofreadTask.systemPrompt` 里写死了四条**必须修**、四条**禁止做**：

必须修：
1. 错别字（形近、音近误用）
2. 乱码（`???`、`?`、``、`□`、乱序方块字、无意义符号堆叠）
3. 多余的重复字（`的的的`、`了了`、`我我`），除非是口吃或强调
4. 明显断错位置的标点

禁止：
1. 改人名、地名、招式名、自造词
2. 改对话语气、方言、口头禅
3. 增删情节、补写
4. 合并或拆分段落

### 3.2 为什么用「带行号的替换」而不是「让模型直接返回全文」

让模型重写全文，它会顺手润色，几百段里改掉几十个无关的地方，用户读着就变形了。
所以要求它按 `[序号] 正文` 逐行回传，然后**一条条比对**：

- 行号对不上 → 抛 `AiError`，整批作废
- 漏行 → 抛 `AiError`
- 重复行号 → 抛 `AiError`
- 行格式不对 → 抛 `AiError`

任何一条不过，这一批就退回原文。**宁可整章不纠，也不留下模型瞎改的痕迹。**

### 3.3 分批策略

`ProofreadTask.chunk()`：每批最多 40 段 / 3000 字。
超了自动切。切点永远在段落边界，不会把一个段落劈两半。

`Proofreader.proofread()` 逐批发、逐批校验，最后 `merge()` 合并且记下哪几段真的变了
（`ProofreadResult.changed`），UI 上只高亮这几段。

### 3.4 三种触发

| 触发 | 时机 | 默认 |
|---|---|---|
| 选中段落 → AI 纠错 | 用户手动 | 开 |
| 整章纠错 | 阅读页菜单 → 「AI 纠错本章」 | 开 |
| 打开章节时自动纠错 | 进章即跑 | **关**（花钱，默认不开） |

### 3.5 缓存

纠错结果按 `书ID+章ID+正文hash` 存本地。第二次打开不重复调模型，也不重复花钱。
原文永远保留在另一个键里，「还原」一键回去。

## 四、key 怎么存

- 只写本机 `SharedPreferences`（后续可换 Android Keystore 包装）
- 不进 `AiConfig.toJson()`（该 Map 里根本没有 key 字段）
- 不进日志（日志只打 `AiRequest.path`）
- 不进备份（备份导出白名单里不含 AI 配置）
- `scripts/check.js` 会扫整个仓库，看到 `sk-…` / `AIza…` / `xai-…` / 私钥头就报错

## 五、出错怎么读

`humanizeHttpError()` 把常见状态码翻成人话：

| 码 | 说的话 |
|---|---|
| 401 / 403 | key 不对、没开通该模型，或 Base URL 填错 |
| 402 | 余额不足，去厂商控制台充值 |
| 404 | Base URL 或模型名不对 |
| 413 | 文本超了上下文，改成按段纠错 |
| 429 | 限流，等几秒 |
| 500~503 | 厂商服务异常 |

设置页的「测试连接」走 `Proofreader.ping()`，发一句「在吗」，让模型回「好」。
回了就是通；不回就把原始错误摆在同一个页面里，可选中复制。