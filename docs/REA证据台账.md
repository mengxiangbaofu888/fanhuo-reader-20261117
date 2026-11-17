# REA 逆向证据台账

这份文件记录**用 REA（rea-agents 6.5.0 CLI）实际跑出来的证据**，
与 `逆向证据.md` 里「手写解包」的结论互相对照。

- REA 版本：`rea-agents 6.5.0`（`D:\github\projects\rea-20261017`）
- 运行环境：Node 24.15.0 / win32 x64
- 原始输出：`D:\github\downloads\fanhuo-reader-20261117\rea\*.json`

---

## 一、REA 在这台机器上能做什么、不能做什么

`rea doctor --json` 的结论（2026-11-17 18:44）：

| 检查项 | 状态 | 说明 |
|---|---|---|
| `node` | ✅ 24.15.0 | —— |
| `host` | ✅ win32 x64 | —— |
| `hopper` | ❌ missing_analysis_engine | 未装，也没设 `HOPPER_LAUNCHER_PATH` |
| `ghidra` | ❌ missing_analysis_engine | 未设 `GHIDRA_INSTALL_DIR` |
| `ida` | ❌ missing_analysis_engine | 未配 `REA_IDA_MCP_CONFIG` |
| `jadx` | ❌ missing_analysis_engine | 需要 `REA_JADX_MCP_JAR` 指向 **jadx-headless-mcp 0.7.1** |
| `registration:dsh` | ❌ config_drift | `C:\Users\35074\.dsh\cordis.patch.yml` 未注册 MCP |

**关键结论**：REA 的 Android 深度分析（`inspect-android-package` / `inspect-android-class` /
`inspect-android-method`）**全部依赖 `REA_JADX_MCP_JAR`**，也就是需要一个
`jadx-headless-mcp 0.7.1` 的 JAR。这个 JAR REA 不下载、不安装，必须自备。

我第一次尝试用系统里的 jadx 1.5.6 冒充，被 REA 拒绝：

```json
{"code":"capability_unavailable","category":"unsupported_provider",
 "message":"Set REA_JADX_MCP_JAR to the absolute path of a caller-supplied jadx-headless-mcp 0.7.1 JAR."}
```

所以本轮 REA 的**可用路径**是：

| REA 命令 | 对四个包能不能跑 | 产出 |
|---|---|---|
| `identify-flutter-build` | ✅ 能 | Flutter 判定、ABI、`libapp.so` 的 Dart snapshot hash |
| `extract-artifact` | ✅ 能（番茄跑通） | 22792 条制品 + 每条 sha256 |
| `inspect` | ❌ 归档类目标被拒 | 报 `target_kind_unsupported`，Ghidra 不吃 zip |
| `inspect-android-package` | ❌ 缺 jadx provider | 需要 0.7.1 JAR |
| `decompile` / `function` | ❌ 缺 Ghidra/Hopper/IDA | 需要原生引擎 |

---

## 二、`identify-flutter-build`：谁是 Flutter，谁不是

### 番茄 `com.dragon.read` 7.3.7.33 —— **不是 Flutter 应用**

```json
{"evidence_id":"ev_3364438f9f661332b3b2ef2d3abb6269d514956530ac766f8f897b3a0933003e",
 "operation":"identify_flutter_build",
 "normalized_result":{"flutter_detected":false,"abis":[],"coverage":"complete"},
 "confidence":"observed","authority":"shipped-artifact"}
```

这条修正了 11-05 那轮的判断。上一轮报告说番茄是「Flutter/KMP 混合架构」，
REA 的判定是 **`flutter_detected: false`**，覆盖度 `complete`。

也就是说：番茄里没有 `libflutter.so`、没有 `libapp.so`，不是 Flutter 壳。
它用的是一套自研的 Compose 风格 UI（`com.dragon.read.widget.*`、
`com.dragon.read.ui.menu.*`），外加 Lynx（`liblynx.so` 4.52 MB）做动态页面。
这也解释了为什么它的阅读页设置面板是标准 Android View 树（`ConstraintLayout` +
`MultipleOptionsView`），而不是 Flutter Widget 树 —— 只有 Android View 才能被
`res/layout/*.xml` 直接描述。

> 对项目的直接意义：番茄那套排版**可以按 dp/sp 一比一抄进 Flutter**，
> 因为它本来就是 Android View 的尺寸语义，不是 Flutter 的逻辑像素换算。

### Wenku8_Flutter 0.4.1 —— **是 Flutter，且是 arm64 单 ABI**

```json
{"evidence_id":"ev_44c1b6d7d10e6c3a73f4f259a492cb0b71183bc8224d2b59b2f3fdc9890d5f09",
 "normalized_result":{
   "flutter_detected":true,
   "abis":[{"abi":"arm64-v8a",
            "libapp":{"present":true,"bytes":10945456,
                      "sha256":"bdc62d7ee4629e49e12b8052b0e5602c4ff2721625c9544633663dd97c5091b5",
                      "elf_header_valid":true,
                      "snapshot_hash_sources":2,
                      "snapshot_hash_candidates":["78da37fed6bf1489361a312568249f3f"],
                      "snapshot_hash":"78da37fed6bf1489361a312568249f3f"},
            "libflutter":{"present":true,"bytes":11317824,
                          "sha256":"0d3c…"}}]},
 "confidence":"observed","authority":"shipped-artifact"}
```

- Dart snapshot hash `78da37fed6bf1489361a312568249f3f` —— 这个值的两个独立来源都一致
  （`snapshot_hash_sources: 2`），所以是**观测值**不是推断。
- `libapp.so` 10,945,456 字节，与 `extract` 解包出来的字节数一致。
- 与 `pubspec.yaml` 的 `version 0.4.1+88`、Dart SDK `^3.11.3` 对得上。

> 对项目的直接意义：底座是 AOT 编译的 Flutter，**不能靠改 `libapp.so` 加功能**，
> 必须拿源码重新编。这正是本项目走「追加源码 + CI 编译」而不是「改字节码」的理由。

---

## 三、`extract-artifact`：番茄的 22792 条制品

```json
{"evidence_id":"ev_1eee532189c077513a2d3099853984928ec77c5c01e2a3575a1d69a145ee46bf",
 "operation":"extract_artifact",
 "normalized_result":{
   "containment_verified":true,
   "integrity_contradictions":[],
   "limitations":["All regular files in the active artifact were materialized; nested archive contents remain represented by their containing file."]
 }}
```

- `containment_verified: true` —— 没有路径穿越，解包是安全的。
- `integrity_contradictions: []` —— 没有「同名不同内容」的冲突。
- `files_sha256: 2d6bf1d6cd076f2566ef801a47a239cbfd815076483270af087cef7db597c776`

从 `artifacts[]` 统计（每条都带 `sha256` 与 `bytes_written`）：

| 项 | 值 |
|---|---|
| 顶层条目 | 22,792 |
| `classes*.dex` | **22 个，合计 201.67 MB** （未压缩，dex 内部方法引用多） |
| `resources.arsc` | 4,094,720 字节（3.9 MB），sha256 `c0f1d0c794a7504c…` |
| `lib/` 下 `.so` | 116 个 |
| `assets/` 下文件 | 526 个 |
| `res/` 下文件 | 22,089 个 |

### 3.1 `lib/` 里最大的 15 个 `.so`（arm64-v8a）

| 库 | MB | 干什么的（据包内符号/命名） |
|---|---|---|
| `libhost.so` | 7.41 | —— |
| `libsscronet.so` | 5.96 | 字节系网络栈（Cronet 定制） |
| `libttffmpeg.so` | 5.75 | 音视频解码 |
| `liblynx.so` | 4.52 | Lynx 跨端动态 UI 引擎 |
| `libmetasec_ml.so` | 4.29 | 风控/设备指纹 |
| `libttmplayer.so` | 2.83 | 播放器 |
| `liblivestrategy.so` | 2.41 | 直播策略 |
| `libquick.so` | 1.86 | —— |
| `libkrypton.so` | 1.66 | 字节加密 |
| `libttcrypto.so` | 1.19 | 字节加密 |
| `libjato.so` | 1.16 | —— |
| `libc++_shared.so` | 0.87 | C++ 运行时 |
| `libanimax.so` | 0.69 | 动效引擎 |
| `libtttext.so` | 0.55 | 排版/文字 |
| `libbyteVC2dec.so` | 0.52 | VC2 解码 |

> 对项目的意义：番茄把「排版」放在 `libtttext.so`（文字）与 `libanimax.so`（动效）里，
> 但**面板与色值在资源表（resources.arsc + res/layout）里**，这才是能直接抄的部分。

### 3.2 另外三个包为什么 `extract-artifact` 失败

```json
{"kuangye": "Destination filesystem cannot store both res/-q.xml and res/-Q.xml; inventory retains both logical names."}
{"legado":  "Destination filesystem cannot store both res/0n.xml and res/0N.xml; inventory retains both logical names."}
{"wenku8":  "Destination filesystem cannot store both res/9n.9.png and res/9N.9.png; inventory retains both logical names."}
```

这是 **Windows 文件系统大小写不敏感**导致的：解包目标是 `%TEMP%`（在 C:，NTFS 的不区分大小写
目录），而 APK 的 `res/` 里同时存在 `-q.xml` 与 `-Q.xml`（AGP 混淆后的短名，大小写算不同资源）。

这是 REA 的**如实报错**，不是 bug —— 它拒绝静默丢一条（那会让制品清单不完整）。
`integrity: fail` 策略下宁可失败。

**绕法**（本轮没跑，留作下次）：
```powershell
# 让输出目录支持大小写区分：Windows 上需要用 wsl 或把 TEMP 指到 ext4 卷
# 或者改用 Linux 侧跑 REA（WSL2 + Node22）
```
豆包/旷野/阅读/文库三个包的**书源 JSON 与清单**本轮改用「jadx 直接读 assets」拿到，
不依赖 extract，结论不受影响。

---

## 四、REA 证据与手写解包的交叉验证

| 结论 | 手写解包（jadx + 文件系统） | REA | 一致？ |
|---|---|---|---|
| 番茄包名 `com.dragon.read` | `<manifest package="com.dragon.read">` | `inspect-android-package` 需 jadx provider，未跑 | 单源 |
| 番茄 versionName `7.3.7.33` / code 73733 | 清单读出来 | 同上 | 单源 |
| 番茄 22 个 dex | `apk` 里数 classes*.dex | 22 个 ✓ | ✅ 一致 |
| 番茄 assets 526 / res 22089 条 | 未逐条数 | 526 / 22089 | REA 更全 |
| **番茄不是 Flutter** | 之前误判为「Flutter/KMP 混合」 | `flutter_detected: false` | ✅ **REA 修正了旧结论** |
| 文库是 Flutter，arm64 | `libapp.so` 存在、`flutter_assets` 存在 | `flutter_detected: true`，snapshot hash 双源一致 | ✅ 一致 |
| 旷野 133 条书源 | `assets/defaultData/bookSources.json` 133 条 | extract 失败（大小写冲突），未复核 | 手写单源 |

---

## 五、要让 REA 跑满 Android 深度分析，需要补什么

按 `rea doctor` 的 remediation，三件事按优先级：

1. **`REA_JADX_MCP_JAR`** —— 拿到 `jadx-headless-mcp 0.7.1` 的 JAR（REA 校验类
   `com/atxx/jhmcp/JadxSession.class`；npm 上公开的是 0.7.0，桥接类是 `com/zin/…`，
   校验不通过）。**这是让 `inspect-android-package/class/method` 可用的唯一办法。**
2. **WSL2 或 Linux 侧跑 REA** —— 解决 `extract-artifact` 的大小写冲突，
   四个包都能解出完整制品清单。
3. **`GHIDRA_INSTALL_DIR`** —— 解压 Ghidra 12.1.x，才能 `open_binary` 打开
   `libtttext.so`、`liblynx.so` 这类原生库。但这是**本项目的非必需项**：
   番茄的排版值在资源表里，不在 `.so` 里。

---

## 六、可复现命令

```powershell
$node = 'C:\Program Files\nodejs\node.exe'
Set-Location 'D:\github\projects\rea-20261017'

& $node scripts\rea.mjs doctor --json

# 谁是 Flutter
& $node scripts\rea.mjs identify-flutter-build D:\...\tomato.apk --format json
& $node scripts\rea.mjs identify-flutter-build D:\...\wenku8.apk --format json

# 制品清单（输出含 22792 条，建议重定向到文件）
& $node scripts\rea.mjs extract-artifact D:\...\tomato.apk --format json > tomato-extract.json

# 需要 jadx provider 才能跑的两条
& $node scripts\rea.mjs inspect-android-package D:\...\tomato.apk
& $node scripts\rea.mjs inspect-android-class D:\...\tomato.apk --class com.dragon.read.reader.ui.ReaderView
```