# 更新日志

本项目版本号遵循 `主.次.补`，`versionCode = 主*10000 + 次*100 + 补`。

## [1.4.0] - 2026-11-17

书源 JS：自己能跑的自己跑，跑不了的明确报错。可搜书源 **824 → 1408**。

### 新增：书源 JS 子集解释器 `js_subset.dart`

真的写了一个 tokenizer + 递归下降求值器，不是拿正则去猜。

先看数据。合并包 2301 条书源里 993 条带 JS，抽出 2693 段脚本按用到的 API 分三档：

| 档 | 条数 | 特征 |
|---|---|---|
| simple | **605** | 纯字符串/正则/算术，如 `result.match(/(\d+)\/?$/)[1]` 拼封面 URL |
| mid | 373 | `java.ajax` / `base64` / `JSON.parse` / `java.put`，要真引擎 |
| hard | 15 | `JavaImporter` + `Packages.javax.crypto`，要 Android Java 反射 |

这一档 **simple 全部由子集解释器执行**，不需要 QuickJS。

支持的语法：

- 字面量：数字、字符串、模板字符串 `` `${a}` ``、正则 `/re/gimsuy`、`true/false/null/undefined`
- 声明：`var` / `let` / `const`
- 运算：`+ - * / %`、`=== !== == != < > <= >=`、`&& || ?? !`、`~` 位运算、三元 `?:`
- 成员：`a.b`、`a[b]`、`a.length`、`a?.b`
- 调用：`f(a)`、`a.m(b)`、IIFE `(()=>{...})()` 与 `(function(){...})()`
- 语句：`var`、`return`、`if/else`、块、表达式语句
- 字符串方法：`match` `replace` `replaceAll` `split` `trim` `trimStart/End`
  `substring` `substr` `slice` `indexOf` `lastIndexOf` `toLowerCase/UpperCase`
  `startsWith` `endsWith` `includes` `charAt` `padStart/End`
- 数组方法：`join` `push` `pop` `shift` `unshift` `slice` `concat` `indexOf` `includes`
- 正则方法：`test` `exec`
- 内建：`String` `Number` `Boolean` `parseInt` `parseFloat` `isNaN`
  `Math.floor/ceil/round/abs/min/max/pow` `JSON.stringify`
  `encodeURIComponent` `decodeURIComponent` `RegExp`

**不在子集里的一律抛 `JsUnsupported`**，上层转成 `RuleUnsupported` 并写明原因，
绝不静默返回空字符串（猜出来的结果会静默返回错数据，比报错难查一百倍）。

### 规则引擎接入 `rule_engine.dart`

```dart
static bool jsLikelySubset(String rule)  // 廉价预筛：含 java./Packages./base64 等就判需引擎
static String? extractJs(String rule)    // 从 `x@js:代码` 或 `<js>代码</js>` 抠出脚本
static String executeJs(...)             // 先子集，认不出抛 RuleUnsupported（1.5.0 在此回落 QuickJS）
```

### 书源分档落盘

- `data/bookSources-merged.json` 每条加 `jsTier` 字段（none / simple / mid / hard）
- `BookSource.jsTier` 读取该字段，`SourceRepository.searchable` 放行 none + simple
- 管理页把「需 JS」拆三档显示：`JS·子集` / `JS·需引擎` / `JS·不支持`
- 首页与统计卡显示分档汇总

### 数字变化

| 项 | 1.3.0 | 1.4.0 |
|---|---|---|
| 书源总数 | 2301 | 2301 |
| **可搜** | 824 | **1408** |
| 需引擎 | 956 | 373 |
| 不支持 | — | 15 |

### 测试

新增 `test/fanhuo/js_subset_test.dart`，50 条用例，脚本全部来自真实书源：

- `var id = result.match(/(\d+)\/?$/)[1]; ...` 拼封面地址
- `result.match(/\('(.*?)'\)/)[1]` 提取括号内容
- `'http://www.31xs.org'+result`
- 各种字符串/数组/正则方法
- **超出子集的（循环、`java.ajax`、`JSON.parse`、`.map` 回调、`++`）必须抛 `JsUnsupported`**

## [1.3.0] - 2026-11-17

这一版打通「搜到书 → 能读正文」，书源 tab 不再只能搜不能读。

### 新增

- **书源书接入上游阅读器** `source_novel_repository.dart`：
  `FanhuoSourceRepository extends NovelRepository`，把书源条目转成上游 `Novel`：
  - `chapters()`：抓目录页（`ruleBookInfo.tocUrl` → 退到书页），
    按 `ruleToc.chapterList/chapterName/chapterUrl` 取章节列表
  - `chapterContent()`：抓正文页，`ruleContent.content` 取 HTML 片段，
    `ruleContent.nextContentUrl` 处理分页（最多 24 页防死循环）
  - 正文 HTML → 纯文本：`<br>`/`<p>` 转换行，`<script>`/`<style>` 丢弃，
    其余标签剥离，实体反转义，空行压缩
- **书籍 id 用稳定负数**：`-900000000` 起，按 `bookUrl` 哈希落位，
  和上游本地书（负数小区间）错开；同一 `bookUrl` 每次拿到同一个 id
- **章节 id 用序号**（1 起）：书源站没有稳定章节 id，
  用「第几章」当 id 才能让上游的进度记录、缓存、下载都对得上
- **绑定表持久化**：`fanhuo.books.v1` 存 novelId → {书名, 作者, bookUrl, 书源}，
  冷启动后书架里还能取回
- **目录/正文都走离线缓存**：`OfflineCacheStore.saveBook/saveChapter`，
  在 `epoch` 内调用，缓存命中就不走网络

### 改动

- `source_search_page.dart`：类名 `FanhuoSearchPage` → `SourceSearchPage`，
  回调从 `onOpenBook(PackedSource, SearchHit)` 改为 `onOpenNovel(Novel)`；
  点书时先 `bind()` 登记再交给阅读页，带「打开中」状态防连点
- `source_bootstrap.dart`：新增 `novelRepository` 与 `cache`，
  书源包加载后顺带 `OfflineCacheStore.load()`
- `fanhuo_home.dart`：搜书卡片改跳 `SourceSearchPage`（之前误跳书源管理页）
- `home_tab.dart`：`FanhuoHomeTab` 新增 `onOpenNovel` 参数并向下传

### 挂载

新增 `scripts/patch-reader.js`，对上游只改 `pages.dart` 两处：

1. `FanhuoHomeTab` 构造时注入 `onOpenNovel: _openFanhuoNovel`
2. `_openFanhuoNovel(Novel)` → `openDetail(context, novel, widget.state, novelRepository)`

链路：**书源搜索页 → 点书 → bind 登记 → openDetail → 上游详情/阅读页**。

## [1.2.0] - 2026-11-17

这一版把「书源」真正挂进 App：底部多一个 tab（挂法 2），首屏内容源连不上时顶部出现提示条（挂法 3）。

### 新增

- **底部第五个 tab「书源」**：`HomeShell` 的 dock 从 4 个变 5 个，
  `home_navigation.dart` 的三条分支（默认 / 离线 / 合并书架）都保留索引 4，
  所以离线、本地模式、合并书架下都能进
- **首屏可用性提示条** `HomeHealthBanner`：启动后异步探一次上游内容源，
  连不上就在顶部贴一条「上游内容源连不上（缺私有 libcpp.so）。书源搜书不受影响。」
  带「去书源」一键跳到第 5 个 tab，可关闭
- **书源运行时** `source_bootstrap.dart`：
  - 11.5 MB 书源包 >2 MB 走 `compute` isolate 解析，不卡首帧
  - 开关状态存 SharedPreferences（按域名，不存整条规则）
  - HTTP 抓取带三级 charset 判定（响应头 → 书源声明 → 内容嗅探），GBK 站点靠这个
- **GBK 兜底解码** `gbk_tables.dart`：`decodeGbk` + `looksLikeGbk`，
  解不出的字输出 `□`，可用 AI 纠错补上下文

### 修复

- `BookSourceRepository` 补 `fromPacked()` 工厂（开关过滤后重建仓库用）
- `source_repository.dart` 的 `_ruleHasJs` 签名统一为单条 `SourceRule`

### 实现说明

改动全部集中在 `scripts/patch-navigation.js`，对上游只做锚点替换：

| 文件 | 改动 |
|---|---|
| `lib/pages.dart` | dock 加项、字段加 `_fanhuoPage`、`_pageWidgets`/`_headers` 各追加一项、监听 `openRequests` |
| `lib/home_navigation.dart` | `tabs` 三条分支加索引 4 |
| `lib/main.dart` | `FanhuoSourceBootstrap.start()` + `home:` 外包 `HomeHealthBanner` |

每处锚点都校验，找不到就退出，不会静默出一个没挂上的包。
「去书源」跳转用 `FanhuoHomeTab.openRequests`（顶层 `ValueNotifier`），
因为 `HomeHealthBanner` 在 `MaterialApp` 外层，拿不到 `HomeShell` 的 State。

## [1.1.0] - 2026-11-17

这一版解决两个问题：**一进首页就「加载失败」**，以及书源太少。

### 修复

- **首屏加载失败**：上游 `main.dart` 启动即连它自己的私有内容接口（`libcpp.so` 那套，
  不在公开源码里），那条链路一失败首屏就白。现在加了一个**完全本地**的入口
  `FanhuoHome`：书源列表读 assets、搜书直连站点、排版面板全本地，断网也能打开。
- **`tag.img@...` 规则整条失效**：最后一段 `tag.img` 曾被属性表误判成「取属性 img」，
  整条选择链在最后一步被吞，封面/插图/`xxx@tag.img@src` 一律取不到。见 1.0.0 的
  `_isAttributeStep` 修复，这版补了回归测试。

### 新增

- **书源扩到 2301 条**：接入 aoaostar/legado（<https://github.com/aoaostar/legado>）
  的全量书源 3907 条，与旷野 133 条按域名去重合并：
  - 旷野 133 条（保留 `probeStatus` 实测值）
  - aoaostar 新增 2168 条
  - 去重掉 1738 条同域名
  - 其中 **可搜 824 条**（无 `@js:` / `<js>`），需 JS 956 条（已从搜索队列剔除）
- **书源仓库层** `source_repository.dart`：懒加载 11.5 MB 的合并包、按来源包分组
  （旷野 / aoaostar）、统计「总 / 可搜 / 需 JS / 带发现页」、关键词与分组筛选
- **书源管理页** `source_manager_page.dart`：统计卡 + 来源筛选 + 单条开关 + 规则预览
- **书源搜索页** `source_search_page.dart`：边搜边出（8 路并发）、实时显示
  「已问 X / N 个源」、结果带来源名与耗时
- **本地首屏** `fanhuo_home.dart`：搜书 / 书源管理 / 阅读排版三张卡

### 已知限制

- 需 JS 的 956 条书源仍然跑不了（引擎没有 JS 沙箱），在管理页标了「需 JS」
- 121 条用 XPath 的规则同样不支持
- 搜书结果取决于各书源站点本身，站点挂了那条就没结果

## [1.0.0] - 2026-11-17

首个正式版。底座为 Wenku8_Flutter 0.4.1（GPL-3.0），叠加番茄阅读页体系、旷野书源与多厂商 AI 纠错。

### 新增

- **番茄阅读页体系**
  - 五套正文底色：纯白 `#d7d7db`、暖黄 `#f7e4cf`、护眼绿 `#c9decb`、静谧蓝 `#c2def0`、夜间 `#262626`
  - 字号三档（小/适中/大）、行距三档（紧凑/标准/宽松）、段距三档
  - 翻页四档：仿真、覆盖、平滑、无动画；左右翻页下生效，上下滚动时自动置灰
  - 点按屏幕翻页、音量键翻页、护眼模式、智能匹配页边距
  - 排版面板按番茄视觉重排：56dp 标题栏 + 12sp 小节标签 + 32dp 选项条 + 5×（52×28dp）色卡横排
- **旷野书屋书源**
  - 内置 133 个阅读格式书源（原包直出，未改一字），132 个带搜索规则
  - 自研规则引擎：CSS 选择器、`@css:`/`@XPath:` 前缀、`{{key}}`/`{{page}}` 变量、GET/POST（含 JSON 配置形 searchUrl）
  - 多源并发搜书：默认 8 路并发，按命中数、响应时间、权重排序合并
  - 书源健康度：启动后后台探测，`probeStatus` 回写（200 / 403 / 502 / 000）
- **AI 正文纠错**
  - 15 个厂商预设：DeepSeek、Kimi、智谱、通义千问、豆包、MiMo、混元、MiniMax、OpenAI、Claude、Gemini、Grok、Mistral、OpenRouter、Ollama、自定义
  - 三种协议：OpenAI 兼容（默认）、Anthropic Messages、Gemini generateContent
  - 纠错任务：错别字、乱码（`???`/``/乱序方块）、重复字（"的的的"）、错位标点、断行错乱、全半角混用
  - 三种触发：手动（选中段落 → AI 纠错）、整章纠错、打开章节时自动纠错（默认关）
  - 结果落到本地缓存，第二次打开不再花钱；原文始终保留，可一键还原
- **工程**
  - GitHub Actions 四关流水线：版本一致性 → 分析/测试 → 三 ABI 构建 → 发版
  - 三 ABI 共用同一 versionCode，可覆盖升级

### 已知限制

- 书源实测：133 个里 30 个首页返回 200、33 个 403（多为 Cloudflare 挑战）、52 个连接失败、13 个 502。真实可搜率需逐源在手机上验证，`probeStatus` 只是首页可达性，不等于能搜到书。
- 55 个书源依赖 `@js:` / `<js>` 脚本规则，规则引擎第一期只实现无 JS 子集（78 个源）。
- MiMo 的对外 Base URL 以小米官方文档为准，设置页可手工改。

## [未发布]

- 书源 JS 沙箱（用 Dart 侧的受限表达式求值替代）
- 章节内容 AI 纠错的分段流式处理，大章节不整段塞进上下文