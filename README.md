# 番茄阅读 Pro · fanhuo-reader-20261117

> **Wenku8_Flutter（GPL-3.0，Flutter/Dart）当底座**
> \+ 番茄免费小说的阅读页排版 / 翻页 / 配色
> \+ 旷野书屋的 133 个书源与多源搜书
> \+ 15 家厂商的 AI 正文纠错

| | |
|---|---|
| 包名 | `com.fanhuo.reader`（与上游 `org.mewx.wenku8_flutter` 不同，可共存） |
| 版本 | `1.0.0` / versionCode `10000` |
| 最低系统 | Android 5.0（沿用底座 `minSdk`） |
| 许可证 | **GPL-3.0**（底座是 GPL-3.0，衍生作品必须同许可证） |
| 出包 | GitHub Actions 打 tag 自动出 arm64 / armv7 / x64 三包 |

---

## 一、四个包，各取什么

| 样本 | 包名 | 取什么 | 怎么取的 |
|---|---|---|---|
| 番茄免费小说 7.3.7.33 | `com.dragon.read` | 正文五色 `#d7d7db/#f7e4cf/#c9decb/#c2def0/#262626`、翻页四档、面板几何（56dp 标题 / 32dp 选项条 / 52×28dp 色卡） | 解包 `resources.arsc` 的 `colors.xml`、`strings.xml`、`layout/*.xml` |
| 旷野书屋 1.5.3 | `com.yystv.www` | 133 条书源 JSON（132 条带搜索）、多源并发搜书 | 直接读 `assets/defaultData/bookSources.json`，未改一字 |
| Wenku8_Flutter 0.4.1 | `org.mewx.wenku8_flutter` | 全部 UI、书架、阅读器内核、本地导入、听书 | 作为源码底座，53,169 行 Dart |
| 阅读 3.23 | `io.legado.app.release` | （只作对照，说明书源格式同源） | —— |

**为什么底座换成 Flutter 而不是继续用阅读**：你第三个需求是「我喜欢 wenku 的 UI」。
Flutter 侧改 `ThemeData` + 加一个 BottomSheet 就能把番茄的排版面板嫁接上去，
阅读那边是 Kotlin XML，改一次编译一次。详见 [`docs/底座变更.md`](docs/底座变更.md)。

---

## 二、目录

```
├── VERSION                         版本号唯一来源
├── CHANGELOG.md                    每版一节（CI 强制检查）
├── lib/fanhuo/                     ★ 本项目全部自研代码（8 个文件，约 76 KB）
│   ├── fanqie_theme.dart           番茄配色 + 面板几何常量
│   ├── fanqie_settings.dart        番茄式设置模型 + 存储序列化
│   ├── fanqie_panel.dart           番茄式排版面板（BottomSheet）
│   ├── book_source.dart            书源模型（Legado 18 字段）
│   ├── rule_engine.dart            规则引擎（默认 / CSS / 变量 / POST）
│   ├── multi_source_search.dart    多源并发搜书 + 合并排序
│   ├── ai_proofread.dart           AI 纠错（15 厂商 / 3 协议 / 分批 / 校验）
│   └── ai_settings_page.dart       AI 设置页
├── data/
│   ├── kuangye-bookSources-133-probed.json   133 条书源 + 实测 probeStatus
│   ├── fanqie-presets.json                   番茄排版预设
│   └── ai-providers.json                     16 个厂商预设
├── scripts/
│   ├── prepare-base.js             拉底座（codeload tarball，失败退 git clone）
│   ├── apply-patches.js            注入：data → assets/fanhuo，lib → lib/fanhuo，改 pubspec + build.gradle
│   ├── sync-lib.js                 只同步 lib/fanhuo
│   ├── bump-version.js             改 VERSION 并同步 pubspec
│   ├── probe-sources.js            并发探书源可达性
│   ├── check.js                    纯 Node 自检（版本 / 数据 / 密钥 / 脚本语法）
│   └── check-dart.js               Dart 括号 / 字符串 / import 体检（没 Flutter SDK 也能跑）
├── docs/
│   ├── 逆向证据.md                 「结论 ← 证据」逐条对应
│   ├── AI接入说明.md               厂商表 / 三协议 / 纠错策略 / key 安全
│   ├── 发版与下载.md               ★ 令牌权限、密钥、CI、下载
│   └── 底座变更.md                 改了底座哪三处、为什么不改 namespace
└── .github/workflows/release.yml   四关流水线
```

---

## 三、本地怎么跑

```powershell
$node = 'C:\Program Files\nodejs\node.exe'
Set-Location 'D:\github\projects\fanhuo-reader-20261117'

& $node scripts\check.js           # 自检 11 项
& $node scripts\check-dart.js      # Dart 体检（8 个文件）

& $node scripts\prepare-base.js    # 拉底座，28 MB 约 8 分钟（第一次）
& $node scripts\apply-patches.js   # 注入数据与代码，幂等
```

出 APK **只能走 CI**：本机没有 Flutter SDK，也没有 Android platform / NDK。
（JDK 17 有，build-tools 36 有，但缺的两样是硬门槛。）

---

## 四、发版

```powershell
& $node scripts\bump-version.js patch      # 1.0.0 -> 1.0.1
# 在 CHANGELOG.md 写 ## [1.0.1] 一节
git add -A; git commit -m "1.0.1：xxx"
git tag -a v1.0.1 -m "v1.0.1"
git push origin main; git push origin v1.0.1
```

CI 四关：`check-version`（版本/tag/CHANGELOG/自检）→ `test`（flutter analyze + test）
→ `build`（3 ABI 并行，同一 versionCode）→ `verify-and-release`（验签 + 建 Release）。

令牌要开哪些权限、密钥怎么生成，全在 [`docs/发版与下载.md`](docs/发版与下载.md)。

---

## 五、已实现 vs 未实现

### ✅ 已实现（有代码，可静态校验）

- 番茄五色正文 + 四档翻页 + 全套面板几何常量
- 番茄式排版面板（字号 / 行距 / 段距 / 背景 / 翻页 / 五个开关 / AI 入口）
- 书源模型与 133 条数据（含实测可达性）
- 规则引擎：默认圆点规则、`@css:`、`{{key}}`/`{{page}}`、`##正则##替换`、POST JSON 形 searchUrl
- 多源并发搜书（8 路泳道 + 超时 + 排序）
- AI：16 厂商 / 3 协议 / 分批 / 行号校验 / 错误汉化 / 连通性测试 / 设置页

### ⚠️ 需要在 CI 上验证

- `flutter analyze` 是否全绿（本机无 Flutter SDK，只做了括号/字符串/import 体检）
- 改 `applicationId` 后 `MainActivity` 能否被找到（`namespace` 保持不动就是为了这个）

### ❌ 还没做

- 把面板挂进上游阅读页菜单（挂法写在 `docs/底座变更.md`，需要改一处上游文件）
- 把书源搜索挂进上游搜索页（同上）
- 书源 JS 沙箱（55 个源用到 `@js:` / `<js>`，现在会明确报「不支持」）
- XPath 规则（8 个源）
- 纠错结果的落盘缓存（`ProofreadResult` 已经带 `changed`，差一层存储）

---

## 六、许可证与来源声明

底座 Wenku8_Flutter 是 **GPL-3.0**，本项目整体随之为 **GPL-3.0**，见 `LICENSE`。

从番茄与旷野取得的只有**数值与规则数据**（颜色值、dp 尺寸、书源 JSON），
不含任何字节码、资源图、字体或商标。见 `NOTICE`。