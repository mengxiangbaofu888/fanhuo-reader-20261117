# 番茄阅读 Pro — 交接记录

> 最后更新：2026-11-17 23:40（Asia/Shanghai）
> 下次继续时先读这一份，不要重新翻聊天记录。

---

## 1. 目标

把三样东西合成一个自己的小说 App：

1. **番茄免费小说**的阅读排版（5 套底色 / 4 档翻页 / 字号行距面板）
2. **旷野书屋 + aoaostar/legado** 的书源（搜书 → 目录 → 正文）
3. **文庫（Wenku8_Flutter）** 的 UI 作为底座
4. 加 AI 纠错字（可自填 key，16 家厂商）
5. 像正常软件一样发版到 GitHub

仓库：<https://github.com/mengxiangbaofu888/fanhuo-reader-20261117>

---

## 2. 当前状态（已知可用）

**最新发布：v1.4.0** — <https://github.com/mengxiangbaofu888/fanhuo-reader-20261117/releases/tag/v1.4.0>

| 资产 | 大小 |
|---|---|
| `fanhuo-reader-1.4.0-arm64.apk` | 50.3 MB |
| `fanhuo-reader-1.4.0-armv7.apk` | 48.5 MB |
| `fanhuo-reader-1.4.0-x64.apk` | 51.8 MB |

CI 四关全绿：`check-version` → `test`（analyze 零问题 + 100 用例）→ `build ×3` → `verify-and-release`。

版本历史：

| 版本 | 内容 |
|---|---|
| 1.0.0 | 首发，书源引擎 + 番茄排版 + AI 纠错，49 个测试 |
| 1.1.0 | 接入 aoaostar 全量书源，2301 条（可搜 824） |
| 1.2.0 | 书源挂进底部第 5 个 tab + 首屏失败提示条 |
| 1.3.0 | 书源书接入上游阅读器（搜到书能读正文） |
| **1.4.0** | **JS 子集解释器，可搜 824 → 1408** |

---

## 3. 关键决策（附理由，别重新讨论）

| 决策 | 理由 |
|---|---|
| **书源 id 用 `-900000000` 起的负随机数** | 上游 `isLocalBook()` 用负数区间，取另一段避开本地书；同一 `bookUrl` 哈希保证稳定 |
| **章节 id 用序号（1 起）** | 书源站没有稳定章节 id，用「第几章」才能让进度/缓存/下载对上 |
| **`FanhuoSourceRepository extends NovelRepository`** | 上游全是接口编程，实现两个方法就能白拿详情页、阅读器、进度、离线下载 |
| **JS 走「先子集，再抛 RuleUnsupported」** | 605 条 simple 档零依赖跑起来；跑不了的明确报错，绝不静默返回空（猜会返回错数据，比报错难查） |
| **`null[1]` 返回 `undefined` 而不是抛错** | 真实 JS 是 TypeError，但书源脚本写这个就是「没匹配到」；让它退化比整条规则炸掉有用。有意偏差，注释和测试名都写明了 |
| **挂载用 `scripts/patch-navigation.js` / `patch-reader.js` 锚点替换** | 只改上游 3 个文件共 14 处，找不到锚点就退出，不静默跳过 |
| **lib/fanhuo/ 是源，_wenku_base/lib/fanhuo/ 是产物** | `apply-patches.js` 从源往底座拷。踩过坑：只改底座不改源，下一次注入就被覆盖 |
| **推送走 Contents / Git Data API** | 本机 `github.com:443` 时通时不通，`api.github.com` 稳定 |
| **git push 全用 Git Data API 一次提多文件** | Contents API 一次只能一个文件，11.5 MB 的书源包传 12 次太慢 |

---

## 4. 还差多少（数字已核实）

| 项 | 数 |
|---|---|
| 书源总数 | 2301 |
| 有 searchUrl | 1811 |
| **当前可搜** | **1408** |
| **缺口** | **403** |

403 拆解：

- **369 条 `mid`** — 要宿主 API（`java.ajax` 186 / `java.get` 185 / `java.put` 149 / `java.getString` 93 / `JSON.parse` 87 / `java.timeFormat` 55 / `base64` 39 / `md5` 23）
- **15 条 `hard`** — `Packages.javax.crypto.Cipher` 签名，建议跳过
- 31 条源自己 `enabled:false`
- **1 条**只卡 XPath

> ⚠️ 之前说「XPath 121 条」是错的。242 条源含 XPath，但 241 条同时可跑，真正只卡 XPath 的只有 1 个。**XPath 这条不用做了。**

---

## 5. 下一步（明天从这里开始）

### 1.5.0 — 接 QuickJS，拿 +240 个源

1. `pubspec.yaml` 加 `flutter_js: ^0.8.7`（Android 端走 JitPack 预编译 QuickJS `.aar`）
2. 写 `lib/fanhuo/js_host_api.dart`：
   - `java.ajax` / `java.get` / `java.post`（复用 `SourceBootstrap.fetch`）
   - `java.put` / `java.get` / `java.getString`（线程内 KV + JSONPath 子集）
   - `java.timeFormat`
   - `base64Decode` / `base64Encode`
   - `md5`（需加 `crypto` 依赖）
3. 沙箱：域名白名单（只允许当前书源域名 + 书页域名）+ 5 秒超时 + 内存上限 + 引擎池（2-3 实例）
4. `RuleEngine.executeJs` 里，子集失败 → 回落 QuickJS

**完成标准**：`check.js` 的可搜数 ≥ 1600，CI 四关绿，发 v1.5.0。

### 1.6.0 — `JSON.parse` + JS 对象遍历，再 +80 → 1728 / 1811 ≈ 95%

---

## 6. 坑与注意

### 必须记住的

- **`apply-patches.js` 会从 `lib/fanhuo/` 覆盖底座** —— 改代码先改源文件
- **`evaluateJs` 返回 `String`** —— 测试里数字要写 `'12'` 不是 `12`
- **`OfflineCacheStore(Directory)` 要传参数** —— 用 `getApplicationSupportDirectory()/fanhuo`，和上游离线缓存分开
- **`HttpClient` 没有 `userAgent` setter** —— 用 `req.headers.set(HttpHeaders.userAgentHeader, ua)`
- **`SearchRequest` 在 `rule_engine.dart`，不在 `multi_source_search.dart`**
- **`check-version` 关没有底座** —— `check-dart.js` 的相对 import 检查要判断 `_wenku_base/lib` 是否存在，否则误报
- **pwsh 的 `Set-Location` 对后续 `[System.IO.File]` 不生效** —— 一律用绝对路径

### flutter_js 的风险（未验证）

拆包看到 `android/build.gradle` 里它自己的 CMake QuickJS 编译**被注释掉了**，注释写 `crashing with SEGV_MAPERR on ARM based devices`，实际用的是 JitPack 上的 `fastdev-jsruntimes-quickjs:0.3.6`。

- CI 里若拉不下 JitPack → 改成本地 fork + 预编译 `.so` 塞 `android/app/libs/`（多半天）
- 包体增量估 +4~6 MB

### 签名（一直没做）

现在三个 APK 是 **debug 证书**，SHA-256 各不相同 → **跨版本覆盖升级会失败**。要正式用：

```powershell
keytool -genkeypair -v -keystore fanhuo-release.jks -keyalg RSA -keysize 2048 -validity 36500 `
  -alias fanhuo -storepass '<库口令>' -keypass '<key口令>' -dname "CN=fanhuo-reader, O=fanhuo, C=CN"
[Convert]::ToBase64String([IO.File]::ReadAllBytes('fanhuo-release.jks')) | Set-Clipboard
```

填进 4 个 secret：`ANDROID_KEYSTORE_BASE64` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD` / `ANDROID_STORE_PASSWORD`，再打一次 tag。

---

## 7. 环境与凭据

| 项 | 位置 |
|---|---|
| 项目根 | `D:\github\projects\fanhuo-reader-20261117` |
| 下载/素材 | `D:\github\downloads\fanhuo-reader-20261117` |
| GitHub PAT（repo + workflow） | `D:\github\downloads\fanqie-reader-20261111\ghh.txt` |
| 干净底座（验锚点用） | `D:\github\downloads\fanhuo-reader-20261117\base-check`（`base.tar.gz` 解出来的） |
| jadx 1.5.6 | 需设 `JADX_CONFIG_DIR` / `JADX_CACHE_DIR` |
| REA CLI | `D:\github\projects\rea-20261017\scripts\rea.mjs`（`rea-agents 6.5.0`） |

本机**没有 Flutter SDK / NDK**，只能靠 CI 构建。

---

## 8. 常用命令

```powershell
cd D:\github\projects\fanhuo-reader-20261117
node scripts\check.js          # 16 项数据自检
node scripts\check-dart.js     # 17 个 dart 文件括号/字符串/import
node scripts\apply-patches.js  # 注入源文件 + 挂导航 + 挂阅读链
node scripts\bump-version.js minor   # 升版本号
```

发版流程（API 推送）：

1. `node scripts/bump-version.js minor`
2. 补 `CHANGELOG.md` 的 `## [x.y.z] - 日期` 小节
3. 三个 check 跑过
4. Git Data API 批量提 blob → tree → commit → 更新 `refs/heads/main` → `workflow_dispatch`
5. 等四关绿 → 建 `refs/tags/vX.Y.Z` 指向 head → 等 `verify-and-release` 绿

---

## 9. 还没做的清单

| 项 | 状态 | 备注 |
|---|---|---|
| QuickJS 真引擎（1.5.0） | 待做 | +240 个源 |
| `JSON.parse` 支持（1.6.0） | 待做 | +80 个源 |
| 15 个签名源 | 建议放弃 | 要逆 `Cipher` 算法，2-4 小时/个 |
| release 签名 | 待做 | 20 分钟，不做就升不了级 |
| 真机验 1728 个源存活率 | 待做 | 之前探旷野 133 条只剩 31 个首页可达 |
| AI 纠错落盘缓存 | 待做 | 现在每次重纠，长章节费 token |
| XPath 规则 | **不需要** | 只卡住 1 个源 |