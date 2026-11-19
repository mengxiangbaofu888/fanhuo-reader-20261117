# 番茄阅读 Pro — 交接记录

> 最后更新：2026-11-19 20:20（Asia/Shanghai）
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

**最新发布：v1.9.1** — <https://github.com/mengxiangbaofu888/fanhuo-reader-20261117/releases/tag/v1.9.1>

| 资产 | 大小 |
|---|---|
| `fanhuo-reader-1.6.0-arm64.apk` | 53.2 MB |
| `fanhuo-reader-1.6.0-armv7.apk` | 51.2 MB |
| `fanhuo-reader-1.6.0-x64.apk` | 54.8 MB |

CI 四关全绿：`check-version` → `test`（analyze 零问题 + 127 用例）→ `build ×3` → `verify-and-release`。
三个包同一 release 证书 `0c43e2cb…`，**可覆盖升级**。

版本历史：

| 版本 | 内容 |
|---|---|
| 1.0.0 | 首发，书源引擎 + 番茄排版 + AI 纠错，49 个测试 |
| 1.1.0 | 接入 aoaostar 全量书源，2301 条（可搜 824） |
| 1.2.0 | 书源挂进底部第 5 个 tab + 首屏失败提示条 |
| 1.3.0 | 书源书接入上游阅读器（搜到书能读正文） |
| 1.4.0 | JS 子集解释器，可搜 824 → 1408 |
| 1.4.1 | 配好 release 签名（此前全是 debug 证书，不能覆盖升级） |
| 1.5.0 | 接 QuickJS + 宿主 API + 沙箱 + 引擎池 |
| 1.5.1 | mid 档放行，可搜 1408 → 1765；书源管理页加「引擎自检」按钮 |
| 1.5.2 | 修引擎桥接：同步回调必须返回 String，异步走 Promise |
| 1.5.3 | **书源包打进 APK**（此前 `apply-patches.js` 漏拷 `bookSources-merged.json`，正式包一直 0 条书源） |
| 1.5.4 | 加载全程留痕（`loadTrace`），0 条时界面直接显示原因 |
| 1.6.0 | 修真因：页面拿的是异步加载前的空快照；加文件日志 + App 内日志查看 |
| 1.7.0 | 加书架（搜索页 ＋ / 我的书源书架）、搜书并发 8→48 且边搜边显示、失败原因上屏、目录分页抓全 |
| 1.8.0 | 修 QuickJS 桥接真根因（Android 走 QuickJsRuntime2，数组过桥必炸）、书源发现页、底部「发现」换掉 |
| 1.9.0 | 发现页重做成「一打开就有书」（榜单+分类+多源并发）、红条探针改判、底部书架换书源书架 |
| **1.9.1** | **日志结构化+分级+耗时、发现页抓取全程打点、一键导出 zip（含环境与书源概况）** |

> 1.5.3~1.6.0 这三版是同一个 bug 的三层排查：
> 先发现书源包没进 APK（1.5.3）→ 进了包还是 0 条（1.5.4 留痕）→
> 查明是 `pages.dart` 里 `late final` 页面拿到加载前的空 `repository`（1.6.0 真修）。
> **教训**：凡是 `catch` 掉的分支都要把原因留给用户看，否则只能靠发布验证猜。

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
| **异步数据一律用 `ChangeNotifier` 通知，页面 `build` 现取** | 1.6.0 的真因：`pages.dart` 的 `late final` 页面缓存了加载前的空 `repository`，界面永远 0 条 |
| **日志写文件 + App 内查看，不依赖 adb** | 本机 `adb devices` 枚举不到 iQOO Neo7（ADB 接口绑 `WinUSB`，非 Google `android_winusb.inf`），三套 adb 都不行 |

---

## 4. 还差多少（数字已核实）

| 项 | 数 |
|---|---|
| 书源总数 | 2301 |
| 有 searchUrl | 1811 |
| **当前可搜** | **1765** |
| **带发现页（exploreUrl）** | **1191** |
| **缺口** | **46** |

真机实测（1.6.0，iQOO Neo7，2026-11-19 00:43）：

```
asset 读取成功：11515771 字节 → 解析完成：2301 条
→ 过滤后：2301 条，可搜 1765 条 → 就绪
共 2301 条 · 可搜 1765 · 需引擎 15 · 带发现页 1191
旷野书屋 133 · aoaostar 阅读源 2168
无 JS 1308 · JS·子集可跑 605 · JS·需引擎 373 · JS·不支持 15
```

搜索实测：搜「湛蓝徽章」命中 286 条，来自 25 个源；问完 1713/1765 个源耗时约 2~3 分钟。

缺口拆解（1.5.1 之后）：

- **15 条 `hard`** — `Packages.javax.crypto.Cipher` 签名，建议跳过
- **31 条**源自己 `enabled:false`（用户可手动开）

> 之前「XPath 121 条」的说法已修正：242 条源含 XPath，但 241 条同时可跑，真正只卡 XPath 的只有 1 个。**XPath 不用做了。**

> `mid` 档 373 条已在 1.5.1 放行进搜索队列（走 QuickJS）。实测能不能搜到书取决于站点本身，不是引擎问题。

---

## 5. 下一步（2026-11-19 晚定下来的路线，明天从这里开工）

真机验证已通过：**书源 2301 条、可搜 1765、带发现页 1191**，加载日志正常。

### 已做完（1.7.0，2026-11-19）

**a. 加书架**
- 搜索结果每条右侧「＋」一键登记 + 收藏
- 新增「我的书源书架」页（`source_shelf_page.dart`），可点进阅读、可移出
- 数据存 `fanhuo.shelf.v1`，与 `_bindings`（「打开过」）分开
- 详情页的「加入/移出书架」还没做（上游详情页在底座里，要另打补丁）

**b. 搜书提速**
- 并发 8→48、单源超时 12s→6s
- 按 `probeStatus` 排序，首页可达（200）最先问
- 每有命中就并进列表重排，不再等全部跑完

**c. 失败原因上屏**
- 目录页无节点 / 取不到章节名 / 正文无规则 / 正文取不到内容
  分别写进 `binding.lastError` 并记日志，带具体规则和 URL

**d. 目录分页抓全**（原计划 1.8.0，顺手做了）
- 每页看 `ruleToc.nextTocUrl`，没有就找「下一页/下頁/next/›」链接
- 上限 200 页，按 URL 去重防死循环，每页记日志

### 已做完（1.8.0，2026-11-19）

**a. 书源发现页** —— `source_explore_page.dart`，支持 `exploreUrl` 三种形态
（分栏文本 684 / JSON 数组 572 / 纯 URL），列表规则优先 `ruleExplore` 退回 `ruleSearch`

**b. 底部「发现」换成书源发现页** —— `patch-navigation.js` 把 `DiscoverPage` 换掉，
`_headers` 那项换成 `ArchiveMasthead(title: '发现', code: '01 / SOURCE ARCHIVE')`

**c. QuickJS 桥接真根因** —— 见「必须记住的」第 2 条，Android 走 `QuickJsRuntime2`，
数组过桥必炸；现在桥上只走 JSON 字符串

### 下一步：1.9.0

1. **真机复验自检**：装 1.8.0 → 书源管理 → 引擎自检。预期「同步 4 项 + 异步 1 项全过」；
   若显示「桥接不通」就是还有地方在传数组
2. **详情页的加入/移出书架**（1.7.0 只做了搜索页和书架页）
3. **底部「书架」tab 也换成书源书架**（现在还是底座那个，虽不像发现页那样必挂，
   但也读不到书源书）

---

## 6. 坑与注意

### 必须记住的

- **`apply-patches.js` 会从 `lib/fanhuo/` 覆盖底座** —— 改代码先改源文件
- **Android 上 `getJavascriptRuntime()` 返回的是 `QuickJsRuntime2`**（不是 `QuickJsRuntime`）。
  它的桥接是 `(String channelName, String message) => channelFunctions[channelName]!.call(...)`，
  直接把 Dart 值返回给 JS；而 `_jsToDart` 会把 JS 数组转成 `List<dynamic>`，
  于是**桥上只要传数组就必炸**：
  `type 'List<dynamic>' is not a subtype of type 'String'`。
  1.5.2 只修了 `QuickJsRuntime`，所以真机一直没好。**桥上只传 `JSON.stringify` 后的字符串。**
- **`flutter_js` 桥接回调必须同步返回 String** —— 返回 `Future` / `null` / `List`
  会在它内部的 `"'$result';"` 里炸成同样的类型错误。
  异步请求（`java.ajax`）只能走 Promise + `__jsResolve` 回填
- **`evaluateAsync` 只等「最外层表达式是 Promise」** —— `java.ajax` 必须单独一整句放最后，
  不能混在字符串拼接里，否则拿到的是空串
- **`evaluateJs` 返回 `String`** —— 测试里数字要写 `'12'` 不是 `12`
- **`OfflineCacheStore(Directory)` 要传参数** —— 用 `getApplicationSupportDirectory()/fanhuo`，和上游离线缓存分开
- **`HttpClient` 没有 `userAgent` setter** —— 用 `req.headers.set(HttpHeaders.userAgentHeader, ua)`
- **`SearchRequest` 在 `rule_engine.dart`，不在 `multi_source_search.dart`**
- **`check-version` 关没有底座** —— `check-dart.js` 的相对 import 检查要判断 `_wenku_base/lib` 是否存在，否则误报
- **pwsh 的 `Set-Location` 对后续 `[System.IO.File]` 不生效** —— 一律用绝对路径
- **每次发版后必须跑 `pwsh scripts/sync-apk.ps1`** —— 把 Release 的包同步到 `D:\github\downloads\fanhuo-reader-20261117\apk\`。本地没有 Flutter SDK/NDK，包只能从 CI 产物取；用户要求本地一直留一份
- **Contents API 大文件会静默失败** —— `js_engine.dart` 推 8 次都失败却显示「OK」，
  远端仍是旧版。**推完必须读回远端内容比对关键字**，不一致就改走 Git Data API（blobs → trees → commits）

### flutter_js 的风险（未验证）

拆包看到 `android/build.gradle` 里它自己的 CMake QuickJS 编译**被注释掉了**，注释写 `crashing with SEGV_MAPERR on ARM based devices`，实际用的是 JitPack 上的 `fastdev-jsruntimes-quickjs:0.3.6`。

- CI 里若拉不下 JitPack → 改成本地 fork + 预编译 `.so` 塞 `android/app/libs/`（多半天）
- 包体增量估 +4~6 MB

### 签名（已解决，2026-11-18）

v1.4.1 起统一用 release 证书，三个包 SHA-256 一致：

```
0C:43:E2:CB:34:B5:6A:2E:E4:05:77:1F:7E:89:0E:3E:D6:B6:7D:91:B8:CA:27:53:7F:0C:0A:66:FE:8C:50:59
CN=fanhuo-reader, O=fanhuo, C=CN，RSA 2048 / SHA256withRSA / 有效期 100 年
```

**keystore 与口令在** `D:\github\downloads\fanhuo-reader-20261117\signing\`：

| 文件 | 内容 |
|---|---|
| `fanhuo-release.jks` | JKS 密钥库（别名 `fanhuo`） |
| `credentials.txt` | storePassword / keyPassword / keyAlias |
| `keystore.b64` | 上面 jks 的 base64（就是 secret 的值） |

4 个 secret 已写入仓库。**丢了 keystore 就永远升不了级，务必备份。**

> ⚠️ 本机系统代理是 `127.0.0.1:7897` 但代理进程没开 →
> 所有 GitHub API 调用要加 `-NoProxy`，python 要 `ProxyHandler({})`。
> pip 也一样，先设 `$env:NO_PROXY='*'`。

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