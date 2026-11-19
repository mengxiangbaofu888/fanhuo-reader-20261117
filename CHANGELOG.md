# 更新日志

本项目版本号遵循 `主.次.补`，`versionCode = 主*10000 + 次*100 + 补`。

## [2.0.0] - 2026-11-19

**书源书终于能进书架了。** 这是一次跨版本的大修：上游有 10 处
`id <= 0` 的守卫，把书源书全部挡在门外。

### 一、点「收藏」毫无反应的真因：上游 10 处负数 id 守卫

`: -930262845`、`: -946874206` —— 书源书的 id 全是负数（`-900000000` 起）。
底座的 `LibraryState` / `OfflineCacheStore` 到处写着：

```dart
if (id <= 0) return;        // setShelfMembership
if (id <= 0) throw ...;     // saveBook
```

这些守卫是「本地书与上游书都是正数」年代的产物，**书源书撞了 10 次**：

| 位置 | 后果 |
|---|---|
| `setShelfMembership` | 点收藏 → 直接 return → **毫无反应** |
| `saveBook` | 目录/正文缓存不落地 → 每次都重抓 |
| `rememberProgress` | 阅读进度不记 |
| `readBook` | 离线缓存读不回来 |

新增 `scripts/patch-negative-ids.js`，把这些守卫从 `id <= 0` 改成 `id == 0`
（0 才是真正的无效 id），**并跳过 `cid`（章节序号从 1 起，那个守卫是对的）**。

本地书 id 区间是 `0x60000000`（正数），书源书是负数，两者不冲突。

### 二、两套书架打通

上游详情页的「收藏」写的是 `LibraryState`，我的「我的书源书架」读的是
`fanhuo.shelf.v1` —— 两套互不相通，所以点了没用。

现在：

- `FanhuoSourceBootstrap.attachLibrary(state)` 在首帧把上游书架注入运行时
- `addToShelf` / `removeFromShelf` 同时写两边
- 启动时把上游书架里已有的负数 id 书补回我的表（迁移旧数据）

`patch-navigation.js` 的幂等判断也修了 —— 原来用「replace 前 120 字符」
判断，插入型改动的前 120 字符就是锚点本身，永远命中，导致 `start()`
被插了 **40 遍**。现在按「replace 去掉 find 之后的尾段」判断，连跑三次确认只有 1 份。

### 三、详情页加载失败：给目录加缓存

`DetailLoaderPage._load()` 每次都调 `chapters()` 现抓目录。站点一慢就整页失败，
而日志显示同样的书第一次抓目录是成功的（1572 章）。

- `OfflineCacheStore.readBook` 放行负数 id（原来也被守卫挡住）
- `FanhuoSourceRepository.cachedChapters(id)` 提供「不联网的目录快照」

### 待办（2.1.0）

- UI 照文庫的书架/书脊视觉效果重做发现页与书架
- 详情页失败时先用缓存目录顶上，再后台重抓

## [1.9.4] - 2026-11-19

用户从日志包和截图看出两个真 bug。

### 一、`@a` 这种裸标签名我压根不认（方框的源头）

发现页抓到 20 本书，界面上全是方框 —— 因为书名是**空字符串**。

日志实锤：

```
部分节点缺 name/bookUrl 被丢弃 | src=笔趣阁④ nodes=30 dropped=20 kept=0
  nameRule=tag.dt@a@text urlRule=tag.dt@a@href
```

`tag.dt@a@text` 是阅读的标准写法：`tag.dt` → 它下面的 `a` 标签 → 取 text。
中间那个 `@a` 是**裸标签名**，等价于 `@tag.a`。

我的 `_applyStep` 只认 `class.` / `id.` / `tag.` / `text.` / `children` 这些前缀，
`a` 不属于任何一个 → 落到 default 分支 → 返回空 → 整条链断掉 → name 为 null → 被丢弃。

**凡是规则里出现 `@a`、`@li`、`@dd`、`@p` 这种裸标签名的书源，全都取不到书名。**

修法：加 `_isBareTagStep()`，把纯字母短名（不含 `.`、不在属性表里）当 `tag.` 处理。

### 二、引擎自检只报整串，看不出哪项错

原来是整串期望值 vs 整串实际值，界面上被截断，根本没法判断。

现在拆成 4 项（封面拼接 / timeFormat / base64Decode / md5）逐个比对，
**只报不一致的那几项**：

```
timeFormat：期望 2026/11/18 09:05，实际 2026/11/18 01:05
```

## [1.9.3] - 2026-11-19

三条都是被用户直接骂出来的。

### 一、日志放 `Android/data` 是蠢决定

用户原话：「老子这他妈是手机不是电脑，位置不好找，而且 Android/data
要的权限很高」。对的 —— Android 11 起那个目录连**文件管理器都进不去**。

改成**下载目录**：

```
/sdcard/Download/fanhuo-logs/
```

文件管理、微信发送、数据线拷贝都能直接用。写入前先探一次（真能写才算数），
失败才逐级退到 Documents → 应用外部目录 → 内部目录。

Manifest 里已有 `MANAGE_EXTERNAL_STORAGE`，不需要额外申请。

### 二、搜索还在「等全部跑完才显示」

1.7.0 我以为做了流式，实际上两个 bug：

**bug 1**：`onResult` 里的 `setState(() { ... })` 只改了内存变量，
但 `_body()` 在 `_phase == loading && _hits.isEmpty` 时**只返回转圈**，
压根不渲染已有的 `_hits`。所以哪怕 3 个源已经回书了，屏幕上还是一个圈。

**bug 2**：`onResult` 在没有命中时也不触发重建，状态栏的「已问 N 个源」不刷新。

修法：

- 只要有结果就渲染列表，**不管搜没搜完**
- 列表末尾挂一行「已问 N / M 个源，还在搜…」，让用户看到进度
- 每个源回来都 `setState` 重建

### 三、发现页：不再盲取前 24 个

真机日志（1.9.2）实锤：

```
第一批抓取完成 | label=分类:玄幻 ok=0 empty=10 fail=14 books=0 ms=9813
补抓下一批 round=1 → ok=0 empty=9 fail=15 books=0
```

问完 48 个源，**一本书都没抓到**。原因不是代码逻辑，是这些源真的都废了：

| 失败类型 | 实例 |
|---|---|
| 域名解析不了 | `get.aoyekanshu.com` `book.lhdqsb.cn` `api-new.iqingguo.com` |
| 连接被拒（反爬） | `m.jhssd.com:57792` `www.tushumi.com:45598` |
| 6 秒超时 | 一大批 |
| **抓到了但规则失效** | `笔趣阁③` `class.l@li` → 0 节点；`笔趣阁④` nodes=30 全丢 |

改法：**有上限的持续抓**

- 按 `probeStatus` 把首页可达的排前面
- **只要还没抓够 36 本，就一直往后问**（原来问完 24 个就收工）
- 上限 80 个源（防个别分类把几百个源全问一遍）
- 抓够了提前停，省流量

## [1.9.2] - 2026-11-19

用 adb 抓到真机日志后，发现三个独立故障。这一版全部修掉，并且**换了书源包**。

### 一、日志一个字都没落盘（1.9.1 白做了）

真机 logcat 里刷满这一行：

```
AppLog 写入失败：FileSystemException: An async operation is currently pending,
  path = '/data/user/0/com.fanhuo.reader/files/logs/app-20261119.log'
```

`RandomAccessFile` 不允许同一句柄上并发 await。24 路并发抓源同时进 `_write()`，
每次都撞车，所以一条都没写进去。

修法：**写队列串行化**

```dart
static Future<void> _queue = Future<void>.value();
static Future<void> _write(String line, DateTime now) {
  _pending++;
  _queue = _queue.then((_) async {
    try { await _writeNow(line); } finally { _pending--; }
  });
  return _queue;
}
```

导出和读取前都 `await _queue`，保证拿到完整内容。

### 二、日志位置改成文件管理器能直接打开的

原来写应用内部目录 `/data/user/0/...`，文件管理器看不到、adb 非 debug 包也进不去
（`run-as: package not debuggable`）。

现在优先写**外部**应用目录：

```
/sdcard/Android/data/com.fanhuo.reader/files/logs/
```

手机自带文件管理器可以直接进、可以直接分享。拿不到外部目录才退回内部。

### 三、发现页 24 个源全是死站

真机日志实锤（1.9.1）：

```
抓取完成 | label=分类:玄幻 ok=0 empty=4 fail=20 books=0 ms=17103
💯全小说① → Failed host lookup: 'quanxs.net'（域名没了）
💯无错小说网① → Connection refused
择日飞升 → Connection reset by peer
🎉醋溜儿文学 → 页面 5.4KB，class.pictext 匹配 0 节点
```

**书源包是 2024 年的数据，大批站点已关停。**

### 四、换书源包

aoaostar 的主源**当天（2026-11-19）刚同步过**，3907 条。抽样 60 个域名探测：

| 指标 | 结果 |
|---|---|
| 2xx/3xx 可达 | **34 / 60（57%）** |
| 典型可达 | www.qidian.com / m.suixkan.com / api.leeyegy.com / www.zwduxs.com |
| 典型失效 | 69shuba.com 403 / siluke.com 503 / ddxs.com timeout / 50zw.so 域名没了 |

对比旧包抽 24 个全挂，差距明显。

新增 `scripts/merge-sources.js`：

- aoaostar 最新全量优先（2124 条去重后）
- 旷野书屋补 95 条（小众但带人工探测）
- 每条重新判定 `jsTier`（none / simple / mid / hard）
- 只保留能吃的字段，包体 20 MB → **10.1 MB**

合并结果：**2219 条 / 可搜 1670 / 带发现页 1142**
分档：none 1423 / simple 588 / mid 175 / hard 33

### 五、取源顺序修正 + 多批补源

书源包按名字排，`💦` `💯` 这类前缀整批堆在最前面，1.9.1 取的正是这 24 个。

- **活源优先**：`probeStatus == '200'` 的排前面
- **多批补源**：一批结果少于 12 本就自动补下一批，最多 3 轮（防无限递归）
- **过滤假分类**：单源分类数 > 200 认为是目录页（努努书坊把 1119 个作者名
  当分类写进去了），跳过

## [1.9.1] - 2026-11-19

发现页打不开书，光看界面查不出来。这一版把日志做成能定位问题的样子，
并且能一键打包导出。

### 一、日志大改

**格式**：单行 + 结构化字段，方便 grep

```
2026-11-19T20:01:33.123+08:00 [WARN ] explore: 列表规则匹配到 0 个节点 | src=💦NB中文网 cat=玄幻 rule=id.novel-list@li!0 bodyKB=42.3 usedExplore=true url=http://www.nbw.la/xuanhuanxiaoshuo/1.htm
```

字段用 `key=value` 放在 `|` 后面，出问题时按 key 一捞就能定位。

**分级**：

| 级别 | 落盘 | 用途 |
|---|---|---|
| DEBUG | 默认不落盘（`verbose=true` 才写） | 抓书源的高频细节，避免刷满盘 |
| INFO | 写 | 关键节点（加载、开始抓、抓完汇总） |
| WARN | 写 | 单源失败、规则匹配 0 节点、节点缺字段 |
| ERROR | 写 | 整批一条书都没抓到，附失败清单 |

**容量**：单文件上限 2 MB → **8 MB**，内存缓存 500 行 → **2000 行**，
保留 7 天（连带导出的 zip 一起清）。

**耗时**：`AppLog.timer()` 直接给 `ms` 字段。

**堆栈**：ERROR 级别额外写最多 12 行堆栈，单独成行（`[STACK]`）。

### 二、发现页抓取全程打点

每个源、每个分类都记，能分清是「源挂了」还是「规则坏了」：

```
开始抓取 | label=分类:玄幻 entries=659 queue=24 concurrency=8
单源抓取失败 | src=xxx cat=玄幻 url=... ms=6001 || error=TimeoutException
列表规则匹配到 0 个节点 | src=xxx cat=玄幻 rule=class.list@li bodyKB=42.3
抓到页面但 0 本书 | src=xxx cat=玄幻 url=... ms=830
部分节点缺 name/bookUrl 被丢弃 | src=xxx nodes=30 dropped=28 kept=2 nameRule=... urlRule=...
抓取完成 | label=分类:玄幻 ok=3 empty=15 fail=6 books=41 ms=12480
一条书都没抓到，可能原因：这些源全部 502/403、或规则全部失效 | failures=源A|玄幻|... ; 源B|玄幻|...
```

### 三、一键导出日志包

日志页右上角新增「导出日志包」，产出标准 ZIP（store 模式，自己实现，不加依赖）：

```
fanhuo-log-20261119T200133.zip
├── 环境.txt            平台 / Dart 版本 / 日志级别 / 目录
├── 书源概况.txt        总数、可搜、需引擎、带发现页、加载轨迹、前 50 个可探索源
└── logs/
    ├── app-20261119.log
    └── app-20261118.log
```

导出后弹窗直接显示绝对路径和大小，附 `adb pull` 命令
（adb 不通时用手机自带文件管理分享）。

> 为什么自己写 ZIP：日志是文本，store 模式几百 KB，为打个包加 `archive`
> 依赖不值得。实现只要正确的 CRC32 + 中央目录，任何解压工具都能开。

## [1.9.0] - 2026-11-19

用户指出两件事：发现页做成了书源列表（和书源 tab 一个样，那分两页干什么），
以及顶部红条一直挂着。

### 一、发现页重做：一打开就有书

1.8.0 的发现页实际上是「书源列表 + 二级分类页」，和书源 tab 重复。
现在照旷野书屋的精选页重做：

```
发现
1216 个「源 × 分类」入口 · 直连站点，不走上游接口
─────────────────────────────
人气榜   新书榜   完结榜          ← 榜单横排，选中带下划线
[封面] [封面] [封面] [封面]        ← 书卡横滑，左上角带阅读数角标
                                   （每张封面用书名的哈希生成渐变，不请求图片）
─────────────────────────────
玄幻  科幻  都市  武侠  仙侠  …    ← 分类 chip，选中反色
[封面] 书名
       简介（最多 3 行）
       作者 · 来源 ·           ＋   ← 带简介的推荐卡，右侧一键收藏
```

**选源策略**（用户选的方案 3）：

| 区块 | 数据源 | 理由 |
|---|---|---|
| 榜单 | 优先旷野书屋的 133 个源 | 分类名规整（人气/热门/完本/连载），榜单好看 |
| 分类网格 | 全部 1216 个带分类的源 | 覆盖广，跨源归并分类名 |
| 兜底 | 旷野源没有的榜单，退到全量 | 不缺项 |

**跨源归并**：`normalizeCategoryName()` 去掉 emoji/装饰符/`小说`等后缀，
把「玄幻奇幻」「玄幻小说」「玄幻」统一成 `玄幻`，这样同一个分类下能凑齐多个源。

**多源并发抓**：一个分类可能有几百个源，全问要几分钟。
现在取前 24 个（并发 8、单源 6 秒超时、整体 25 秒封顶），
每本按 `bookUrl` 去重，通常能凑出几十本。

### 二、顶部红条：查清来源后改了探针

横幅文案来自底座 `fanhuo/home_tab.dart` 的 `HomeHealth.probe()`：

```dart
final text = await _channel.invokeMethod<String>('request', {...});
// channel = 'org.mewx.wenku8/legacy_api'
```

原生端要 `dlopen` 文庫作者的私有 `libcpp.so`。那个 so 不在开源仓库里，
所以**永远失败、红条永远挂着**。而书源链路（搜索/目录/正文）压根不走它。

`1.8.0` 之前 `HomeHealthBanner` 是我自己 patch 进去的，当时用它提示「去书源」。
现在书源已经全面可用，它就成了纯噪音。

改动：

- `HomeHealth.probe()` 改成**看书源运行时是否就绪**（书源包加载完 = 健康），
  不再探上游私有接口
- 文案从「上游内容源连不上（缺私有 libcpp.so）。书源搜书不受影响。」
  改成「上游内容源不可用（缺私有 libcpp.so）。只用书源的话可以忽略。」

### 三、底部「书架」换成书源书架

底座 `ShelfPage` 读的是上游 `NovelRepository`（本地书 + 上游自己的书），
书源书在另一个 id 空间（负数 `-900000000` 起），那个页面看不到。

`patch-navigation.js` 增加锚点，把 `ShelfPage(...)` 换成 `SourceShelfPage(...)`，
`_headers` 里对应那项换成 `ArchiveMasthead(title: '书架', code: '02 / SOURCE SHELF')`。

现在底部五个 tab：**发现（书源）/ 书架（书源）/ 本地 / 我的 / 书源**，
前两个不再是死页面。

## [1.8.0] - 2026-11-19

三件事：修 QuickJS 桥接（引擎之前其实全不可用）、书源发现页、底部「发现」换掉。

### 一、QuickJS 桥接的真正根因（1.5.2 修错了地方）

1.5.0 起引擎自检一直报：

```
type 'List<dynamic>' is not a subtype of type 'String' of 'optimized out'
```

1.5.2 我以为修好了，其实修的是 `QuickJsRuntime`（老实现）。
**Android 真机走的是 `QuickJsRuntime2`**：

```dart
if (Platform.isAndroid && !forceJavascriptCoreOnAndroid) {
  runtime = QuickJsRuntime2(stackSize: stackSize);
}
```

它的桥接是：

```dart
(setToGlobalObject as JSInvokable).invoke([
  'sendMessage',
  (String channelName, String message) {
    return channelFunctions[channelName]!.call(jsonDecode(message));  // ← 直接把 Dart 值返回给 JS
  }
]);
```

而 `_jsToDart`（`wrapper.dart:209`）把 JS 数组转成 **`List<dynamic>`**：

```dart
} else if (jsIsArray(ctx, val) != 0) {
  final ret = [];
  ...
  return ret;
}
```

于是：JS 传数组 → Dart 拿到 `List` → 要作为 `String` 返回给 FFI → **类型炸掉**。

这不只是自检的问题：`java.ajax`、`java.getUrl` 全都走同一条桥，
**所以 373 个 mid 档源实际上从来没跑起来过**，能搜到书的只有 605 个 simple 源。

修法：**桥上只传字符串**。

```js
// 改前：数组过桥，必崩
sendMessage('__host__', [id, method, params]);
// 改后：JSON 字符串过桥
sendMessage('__host__', JSON.stringify([id, method, params]));
```

Dart 侧统一 `jsonDecode`，并兼容老的 `List` 路径。

### 二、自检改成三步，能直接指出坏在哪

1. **桥接**：JS 发一条字符串、Dart 回一条（`base64Encode('ok')` → `b2s=`）
2. **同步脚本**：正则/拼接/时间/base64/md5
3. **异步脚本**：`java.ajax` 返回 Promise

结果多一档「桥接不通」，前一步失败就不往下跑。

### 三、书源发现页（替代上游那个必然失败的「发现」）

底座 `DiscoverPage` 连它自己的私有 `libcpp.so` 接口，拿不到 so 就永远
「书籍加载失败」。而书源里有 **1256 个带 `exploreUrl`**，自带分类目录。

新增 `source_explore_page.dart`，支持 `exploreUrl` 的三种形态：

| 形态 | 数量 | 样子 |
|---|---|---|
| 分栏文本 | 684 | `玄幻奇幻::/xuanhuan/list-1-{{page}}.html` |
| JSON 数组 | 572 | `[{"title":"都市人生","url":"...?page={{page}}"}]` |
| 纯 URL | 少量 | 只有一个地址，当成唯一分类 |

列表规则优先 `ruleExplore.bookList`，没有就退回 `ruleSearch.bookList`
（327/328 的分栏源靠这个兜住）。

界面：书源列表 → 点进某源 → 顶部横滑分类 chip → 抓书单 → ＋收藏 / 打开阅读，
底部有上一页 / 下一页。

### 四、底部「发现」tab 换成书源发现页

`patch-navigation.js` 增加一个锚点，把 `pages.dart` 里的
`DiscoverPage(...)` 换成 `SourceExplorePage(...)`。
红色「上游内容源连不上」的横幅还会在（那是底座自己的状态提示），
但点进「发现」现在能看到东西了。

## [1.7.0] - 2026-11-19

三个真问题：搜到的书能收进书架、搜书提速、加载失败能看出原因。
顺带把「只有几十章」的分页目录也修了。

### 一、加书架

之前搜到的书点进去只能读，收不进书架 —— 因为书源书是负数 id 空间，
和上游书架（本地书 + 上游自己的书）不是一套。

改动：

- `FanhuoSourceRepository` 增加书架：`addToShelf` / `removeFromShelf` /
  `shelfBooks` / `isOnShelf`，存 `fanhuo.shelf.v1`
- **搜索结果每条右侧加「＋」** —— 点一下直接登记 + 收藏，不用先进阅读页
- **新增「我的书源书架」页** —— 列出收藏的书，点击进入阅读，右侧可移出
- 书源 tab 首页多一张「我的书源书架」卡片

> 为什么书架和 `_bindings` 分开存：`_bindings` 是「这本书被打开过」的登记表，
> 书架是用户主动收的。混在一起会让所有打开过的书自动出现在书架里。

### 二、搜书提速

真机实测（1.6.0）：搜「湛蓝徽章」要问 1765 个源，跑完 1713 个约 2~3 分钟，
期间界面只有转圈。

| 项 | 改前 | 改后 |
|---|---|---|
| 并发 | 8 | **48** |
| 单源超时 | 12 秒 | **6 秒** |
| 源顺序 | 原序 | **按 `probeStatus` 排序，首页可达的 200 先问** |
| 结果呈现 | 全部跑完才显示 | **每有一个源命中就并进列表重新排序** |

网络 IO 为主，48 路不会打满 CPU；6 秒不回基本就是死了。

### 三、加载失败要说原因

之前点书进详情，若目录抓失败只会转圈或空白，分不清是 `tocUrl` 抓不到、
`chapterList` 匹配 0 条、还是相对路径拼错。

现在每一环失败都写进 `binding.lastError` 并记日志：

```
目录页没匹配到章节（规则 chapterList=class.list@tag.dd），书源可能改版了；目录页：https://...
目录规则取不到章节名（chapterName=tag.a@text）
正文页没取到内容（content=class.content@html），章节页：https://...
这个书源没有正文规则（ruleContent.content）
```

### 四、目录分页抓全（「只有几十章」的真因）

很多站的目录是分页的（`?page=1` 只给 50 章），之前只抓第一页，
所以 3000 章的书只显示 50 章。

现在：

1. 每抓完一页就看 `ruleToc.nextTocUrl`
2. 没有规则就退化成「找文案是 `下一页` / `下一頁` / `下页` / `next` / `›` 的链接」
3. 一路跟到底，上限 200 页（3000 章 × 每页 50 章也才 60 页）
4. 同章去重（分页边界容易重复）、页面去重（防死循环）
5. 每页都记日志：`目录第 N 页：X 个节点，新增 Y 章，下一页=...`

### 测试

新增 `test/fanhuo/search_ranking_test.dart`：

- 同名书按耗时升序（快源在前）
- 完全命中 > 前缀 > 包含 > 作者 > 其他
- 空关键词按耗时排，不炸
- `probeStatus == '200'` 才算首页可达
- mid 可搜、hard 不可搜（口径没退）

## [1.6.0] - 2026-11-18

**找到「加载显示 2301 条但列表 0 条」的真因了，同时加上文件日志与 App 内日志查看。**

### 真因：页面拿的是异步加载前的空快照

`pages.dart` 里书源页是 `late final`，在 `HomeShell.initState` 里一次性构造：

```dart
late final FanhuoHomeTab _fanhuoPage = FanhuoHomeTab(
  repository: FanhuoSourceBootstrap.instance.repository,   // ← 此刻还是空仓库
  ...
);
```

而书源包 11.5 MB 是**异步**读取 + `compute` 解析的，等它完成时页面早就建好了。
于是同一屏出现两个时刻的数据：

| 界面元素 | 数据来源 | 结果 |
|---|---|---|
| 「加载：asset 10.98 MB，解析 2301 条，就绪」 | `bootstrap.loadTrace`，实时 | 正确 |
| 「共 0 条 · 可搜 0」 | `widget.repository.stats()`，构造时快照 | 永远是 0 |

修法：

1. `FanhuoSourceBootstrap` 改 `extends ChangeNotifier`，仓库替换后 `notifyListeners()`
2. `FanhuoHome` / `SourceManagerPage` 在 `initState` 订阅它，`dispose` 退订
3. 两个页面 `build` 时**现取** `FanhuoSourceBootstrap.instance.repository`，
   不再用构造时传进来的那份快照

### 新增：文件日志 `app_log.dart`

- 写到 `应用私有目录/logs/app-YYYYMMDD.log`（`path_provider`，无需存储权限）
- 按天切分、单文件 2 MB 上限、保留最近 7 天
- 内存留最近 500 行，界面秒开
- 已打点的关键路径：
  - `开始读 asset` / `asset 读取成功（字节数）`
  - `解析完成 N 条` / `过滤后 N 条，可搜 M 条`
  - `书源运行时就绪` / `加载失败：原因 + 堆栈`

### 新增：App 内日志查看页

书源管理页右上角「运行日志」：

- 滚动查看 500 行
- **复制全部**（把内容发给开发者即可）
- 清空
- 显示日志目录与 `adb shell run-as` 取法

### 关于 adb

本机 `adb devices` 枚举不到 iQOO Neo7（Windows 设备管理器里状态正常，
ADB 接口绑的是 `WinUSB` 而非 Google 的 `android_winusb.inf`）。
试过三套 adb（37.0.1 / 33.0.2 / 小米助手版）都不行。
所以不依赖 adb：日志写文件、在 App 里直接看。

## [1.5.4] - 2026-11-18

1.5.3 已经把书源包打进 APK 了（`assets/flutter_assets/assets/fanhuo/bookSources-merged.json`，11.54 MB，
下载 Release 资产后用 zip 检查确认过），但界面仍显示「共 0 条」。

说明问题**不在打包，在加载**。1.5.3 里 `_load()` 的 `catch` 把异常完全吞掉，
只留下一个空仓库，用户端看不出是 asset 读不到还是 JSON 解析失败。

### 改动

1. **加载过程留痕** `FanhuoSourceBootstrap`
   - 记录每一步：`asset 11.54 MB，解析 2301 条，过滤后 2301 条，就绪`
   - 出错时把原因存进 `loadError`，不再静默
2. **读 asset 加兜底**
   - 先试 `assets/fanhuo/bookSources-merged.json`
   - 失败再试 `assets/assets/fanhuo/bookSources-merged.json`（不同 Flutter 版本 key 前缀不同）
   - 两条都失败时，用 `AssetManifest` 列出包内所有 `fanhuo` 资源名，一起抛出来
3. **管理页顶部显示「加载：」一行**
   - 正常时灰色（`asset 11.54 MB，解析 2301 条，就绪`）
   - 0 条时红色，直接把失败原因印在界面上

### 为什么这么做

前两个版本（1.5.2 / 1.5.3）我都是靠猜：先猜是引擎，再猜是打包。
`catch (_) {}` 让每次猜测都要走一轮完整发布才能验证。

这一版把所有中间状态显式化：装上去后如果还是 0 条，界面会直接告诉我
是「读不到 asset」还是「解析出 0 条」还是「被 enabled:false 全过滤掉了」，
一次就能定位。

> 引擎自检的那个 `List<dynamic>` 报错仍未解决，属于独立问题，
> 等书源列表先正常了再查。

## [1.5.3] - 2026-11-18

修一个**从 1.1.0 起就一直存在、但一直没被发现**的严重问题：正式包里根本没有书源。

### 主问题：书源包从来没被打进 APK

截图证据：书源 tab 显示「共 0 条 · 可搜 0」，书源管理里「没有匹配的书源」。

根因在 `scripts/apply-patches.js` 的第 2 步：

```js
for (const name of [
  'kuangye-bookSources-133-probed.json',   // ← 只有这个
  'fanqie-presets.json',
  'ai-providers.json',
]) { ... }
```

而 `source_bootstrap.dart` 加载的是：

```dart
static const _assetPath = 'assets/fanhuo/bookSources-merged.json';
```

**Code 读合并包，脚本只拷了旷野 133 条的旧包** —— 所以 `_repository` 一直是空的，
`stats()` 全是 0，搜索队列也是空的。本地的 `check.js` 只检查了 `data/` 里的源文件，
没检查它有没有被拷进 `assets/`，CI 四关全绿却打出空包。

修法：

1. 拷贝清单加上 `bookSources-merged.json`
2. 拷完立刻校验：文件存在且 > 5 MB，否则脚本直接退出
3. `check.js` 增加两项：
   - `apply-patches.js` 是否包含这个文件名
   - 底座 `_wenku_base/assets/fanhuo/bookSources-merged.json` 是否存在且 > 5 MB

### 次问题：引擎自检的报错信息

「脚本执行失败：type 'List<dynamic>' is not a subtype of type 'String' of 'optimized out'」
是 `flutter_js` 内部 `return jsEval(ctx, "'$result';").rawResult` 抛的，
被上层 `catch (_)` 吞成了通用文案，看不出真实原因。

现在引擎执行改成三步，每步单独报错：

1. 胶水注入 → 失败报「胶水注入失败」
2. 全局变量注入 → 失败报「全局变量注入失败」
3. `evaluate(script)` 同步求值 → 报错时只留第一行（去掉堆栈）

同步结果若是空串或 `[object Promise]`，再走 `evaluateAsync` 并 `executePendingJob()`
跑一遍 microtask 队列；两条都拿不到值时，把 Promise 的状态和已 resolve 值打出来
（`promise:fulfilled:xxx` / `promise:pending:` / `promise:rejected:xxx`），
让「引擎不能用」变成一条能看懂的信息。

> 这一步是诊断增强，不是功能修复。`java.ajax` 这类异步宿主 API 在 QuickJS 上
> 能不能等回结果，要看 1.5.3 装上去自检的输出才能定。

## [1.5.2] - 2026-11-18

修 1.5.1 引擎自检报的那个错。

### 现象

点「引擎自检」，结果显示：

```
脚本执行失败：type 'List<dynamic>' is not a subtype of type 'String'
of 'optimized out'
#0 _TypeError._throwNew (dart:core-patch/errors_patch.dart:108)
#1 Function._apply (dart:core-patch/function_patch.dart:11)
```

### 根因

`flutter_js` 的桥接回调是**同步**的（FFI 直接调），实现里这么写：

```dart
String? result = 'NO RESULT YET';
result = mapJsBridge[channelNameStr]!.call(jsonDecode(messageStr));
...
return QuickJsRuntime.jsEval(ctx, "'$result';").rawResult;
```

三个致命约束：

1. 回调**必须同步返回**，返回 `Future` 会被整个塞进 `"'$result';"`
2. 返回值**只能是 `String`**，返回 `null` / `List` / `Map` 都会在类型转换里炸
3. 我第一版写的是 `async` 回调 + `return null` —— 两条都踩中

### 修法

把宿主 API 拆成两套通道：

| 类型 | 通道 | 例子 |
|---|---|---|
| **同步** | `sendMessage` 直接返回字符串 | `java.put` / `java.getString` / `java.timeFormat` / `base64` / `md5` |
| **异步** | 返回 `Promise`，Dart 拿到结果后回调 `__jsResolve` | `java.ajax` / `java.getUrl` / `java.post` / `java.connect` |

JS 侧胶水改成：

```js
// 同步：桥接回调的返回值就是结果
function __nativeCall(method, params) {
  var r = sendMessage('__host__', [id, method, params]);
  return r === null || r === undefined ? '' : String(r);
}
// 异步：返回 Promise，Dart 稍后调 __jsResolve
function __nativeRequest(method, params) {
  return new Promise(function (resolve) {
    __jsResolveResolvers[id] = resolve;
    sendMessage('__host__', [id, '__req__' + method, params]);
  });
}
```

Dart 侧遇到 `__req__` 前缀就 `unawaited(_request(...))` 并立刻返回空串，
请求完成后 `evaluate('window.__jsResolve(id, value)')` 回填。

### 自检也加强了

现在跑**两段**：

1. **同步 4 项**：正则捕获组 + 字符串拼接、`java.timeFormat`、`base64Decode`、`md5`
2. **异步 1 项**：`java.ajax(...).then(...)` —— 验证 Promise 桥真的能回来

结果文案变成「同步 4 项 + 异步 1 项全过」「同步部分不对」「异步桥不对」三种，
出错时能直接看出是哪一半坏了。

> 为什么异步那一项要单独写一句：`evaluateAsync` 只在脚本**最外层表达式是 Promise**
> 时才等它。所以 `java.ajax` 必须放在最后一整句，不能混在字符串拼接里。

## [1.5.1] - 2026-11-18

把 QuickJS 引擎真正接进搜索队列，并给一个能自查引擎的按钮。

### 可搜书源 1408 → 1765

`SourceRepository.searchable` 放行 `jsTier = mid` 的源：

| 档 | 条数 | 走哪条路 | 1.5.1 |
|---|---|---|---|
| none | 1308 | 纯选择器 | 可搜 |
| simple | 605 | 内置子集解释器 | 可搜 |
| **mid** | **373** | **QuickJS 引擎** | **本轮放行** |
| hard | 15 | 要 `Packages.javax.*` | 仍剔除 |

`scripts/check.js` 的可搜下限从 1400 提到 1600，避免以后悄悄退回去。

### 新增：引擎自检按钮

书源管理页统计卡下面多了个「引擎自检」。点一次跑一段固定脚本，覆盖：

- `result` 全局变量 + 正则捕获组
- 字符串拼接与 `parseInt(id/1000)`
- `java.timeFormat('1794963907')` → `2026/11/18 09:05`
- `base64Decode('5Lit5paH')` → `中文`
- `md5('abc')` → `900150983cd24fb0d6963f7d28e17f72`

结果分四档显示：**引擎可用 / 引擎不可用 / 脚本执行失败 / 结果不对**，并给出耗时。

### 为什么要这个按钮

单元测试跑在桌面 Dart VM 上，**没有 QuickJS 原生库**，只能验证「回落逻辑对不对」，
验证不了「引擎真能跑」。而 `flutter_js` 的作者在自己的 CMake 里写过
`crashing with SEGV_MAPERR on ARM based devices` —— ARM 设备上有前科。
这个按钮让你不连电脑就能看到结论。

自检脚本**不联网**（注入假 fetch），断网也能跑。

### 测试

新增 `test/fanhuo/source_tier_test.dart`：

- mid 进搜索队列、hard 不进（4 条源的夹具逐条核名）
- 统计口径：mid 计入可搜、hard 计入「需引擎」
- 自检在无原生库环境下返回可读结果而不是抛异常
- 自检脚本不触发网络

## [1.5.0] - 2026-11-18

接真 JS 引擎（QuickJS），子集解释器跑不了的书源脚本有了第二道解法。

### 新增 `js_host_api.dart`：书源脚本的宿主 API

书源脚本里的 `java.ajax` / `base64Decode` / `md5` 这些**不是 JS 标准**，
是「阅读」App 用 Rhino 塞进去的 Java 对象。换成 QuickJS 之后得自己实现：

| API | 说明 | 用到它的源 |
|---|---|---|
| `java.ajax(url)` | 抓页面，复用书源的 fetch（含关证书/UA/GBK） | 186 |
| `java.getUrl(url)` / `java.get(x)` | 同上；`java.get` 按参数是否以 `http` 开头区分 URL 与 KV key | 185 |
| `java.post(url, body)` | POST | 6 |
| `java.put` / `java.get(k)` / `java.getString(path)` | 线程内 KV + JSONPath 子集（`$.a.b[2].c`） | 149 + 93 |
| `java.timeFormat(ts, pattern)` | 秒/毫秒时间戳格式化 | 55 |
| `base64Decode` / `base64Encode` | | 39 |
| `md5` / `md5Encode` / `md5Encode16` | | 23 |

### 新增 `js_engine.dart`：引擎池 + 沙箱

- **引擎池 2 实例**：QuickJS 建实例要几十毫秒，8 路并发搜索不能每次新建
- **域名白名单** `HostAllowList`：只允许当前书源域名 + 书页域名（含子域与同根 CDN）
- **单次执行 5 秒硬超时**：超时就废掉该实例重建（QuickJS 没法安全中断长脚本）
- **单次最多 16 个网络请求**：防死循环刷站
- **只注入胶水函数**：拿不到文件系统、拿不到 Android 反射、拿不到 Dart 对象

### `RuleEngine.executeJsWithEngine`：三级回落

```
tier=simple → 子集解释器 →（认不出）→ QuickJS →（失败）→ null
tier=mid    → 直接 QuickJS →（失败）→ null
tier=hard   → 直接 null（要 Packages.javax.* ，做不到）
```

### 测试

新增 `test/fanhuo/js_host_api_test.dart`，21 条用例：

- 白名单：主域/子域/CDN 放行，异域与 `example.com.evil.test` 拒绝，非法 URL 不炸
- `java.ajax`：白名单外**不发请求就抛**、请求数上限、抓取失败返回空串
- KV 与 JSONPath：`$.a.b[2].c` 取值、路径不存在返回空
- `base64` 往返、`md5` 已知值、`timeFormat` 秒/毫秒/空值
- 三级回落：hard 不跑、simple 不碰引擎、mid 在无原生库环境返回 null

### 数字

可搜书源仍为 1408（引擎只对 `mid` 档生效，要让它们进搜索队列还需要按 `jsTier`
放行 mid，那是 1.5.1 的事——先确认引擎在真机上跑得通）。

## [1.4.1] - 2026-11-18

只有一件事：**配好 release 签名**，从这一版起才能真正覆盖升级。

### 变更

- 生成 release keystore（RSA 2048，SHA256withRSA，有效期 100 年），写入 4 个 GitHub secret：
  `ANDROID_KEYSTORE_BASE64` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD` / `ANDROID_STORE_PASSWORD`
- CI 的「配置签名」步骤此前一直走 debug 兜底分支，
  现在会真的写 `_wenku_base/android/key.properties` 并用 `distribution` 签名配置

### 为什么必须做

1.0.0～1.4.0 六个包的签名证书 SHA-256 各不相同（debug 证书每次生成都不同），
所以**跨版本覆盖安装会失败**，只能卸载重装，书架和进度全丢。

从 1.4.1 起所有版本共用同一套证书，覆盖升级正常。

> ⚠️ 1.4.0 及更早与本版签名不同，**第一次升到 1.4.1 仍需卸载重装一次**；
> 之后 1.4.1 → 1.5.0 → … 就能直接覆盖了。

### 功能

无变化，代码与 1.4.0 完全一致（可搜 1408 条书源）。

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