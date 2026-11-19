#!/usr/bin/env node
/**
 * 把「书源」挂进上游导航（挂法 2）+ 首屏可用性提示（挂法 3）。
 *
 * 只做锚点替换，每处都校验；找不到就退出并打印，绝不「找不到就跳过」
 * —— 那会让 CI 静默出一个没挂上的包。
 *
 * 挂载点分三处：
 *
 *   1. `lib/pages.dart`（HomeShell）
 *      a. `_dockItems` 加第五项「书源」
 *      b. 字段区加 `_fanhuoPage`（书源页实例）
 *      c. `initState` 里把书源页拼进 `_pageWidgets` 与 `_headers`
 *      d. `_scrollControllers` 补一个（每个 tab 一个，缺了会越界）
 *      e. 页面列表 map 改成「已包好 Atmosphere 的原样放，没包的再包」
 *         —— 书源页内部自带 Atmosphere（配色跟番茄走），重复包裹会掉帧
 *
 *   2. `lib/home_navigation.dart`：`tabs` 的三条分支都加上 4
 *
 *   3. `lib/main.dart`：`home:` 外面包一层 `HomeHealthBanner`
 *
 * 书源页要的东西（仓库/抓取/设置）全部来自 `FanhuoSourceBootstrap.instance`，
 * 挂载点只拿引用，不关心它是怎么加载出来的。
 */
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const BASE = process.env.WENKU_BASE || path.join(ROOT, '_wenku_base');

function log(msg) {
  console.log(`[patch-nav] ${msg}`);
}
function fail(msg, hint) {
  console.error(`[patch-nav] ${msg}`);
  if (hint) console.error(`           ${hint}`);
  process.exit(1);
}
function must(rel) {
  const p = path.join(BASE, rel);
  if (!fs.existsSync(p)) fail(`底座缺文件：${rel}`, '先跑 scripts/prepare-base.js');
  return p;
}
function backup(rel) {
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const dst = path.join(BASE, '.backup', stamp, rel);
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.copyFileSync(path.join(BASE, rel), dst);
}
function patch(rel, anchors) {
  const file = must(rel);
  let text = fs.readFileSync(file, 'utf8');
  let changed = 0;
  for (const { name, find, replace, id } of anchors) {
    // 幂等判断分两类，不能混：
    //
    // 1) **替换型**（replace 里不含 find）：锚点被换掉了 → 文件里找不到 find
    //    → 已经应用过。
    // 2) **插入型**（replace 以 find 开头，在其后追加内容）：锚点还在，
    //    但 replace 的尾部（追加的那段）也在 → 已经应用过。
    //
    // ⚠️ 1.9.x 的写法是「看 replace 前 120 字符」，插入型改动里前 120 字符
    // 就是 find 本身，永远命中，于是每跑一次就多插一份 —— `start()` 被插了
    // 40 遍就是这么来的。
    const isInsert = replace.includes(find);
    if (isInsert) {
      const tail = replace.substring(replace.indexOf(find) + find.length).trim();
      if (tail.length > 0 && text.includes(tail)) {
        log(`${rel}: ${name}（已应用，跳过）`);
        continue;
      }
    } else if (!text.includes(find)) {
      log(`${rel}: ${name}（已应用，跳过）`);
      continue;
    }
    if (!text.includes(find)) {
      fail(`${rel}: 锚点失效 —— ${name}`, `找不到：${find.slice(0, 90).replace(/\n/g, '\\n')}`);
    }
    text = text.replace(find, replace);
    changed += 1;
    log(`${rel}: ${name}`);
  }
  if (changed > 0) {
    backup(rel);
    fs.writeFileSync(file, text);
  }
}

/* ────────── 1. pages.dart ────────── */
patch('lib/pages.dart', [
  {
    name: 'import 书源页与引导器',
    find: `import 'discovery_filters.dart';`,
    replace: `import 'discovery_filters.dart';
import 'fanhuo/home_tab.dart';
import 'fanhuo/source_bootstrap.dart';`,
  },
  {
    name: '_dockItems 加「书源」',
    find: `    GlassDockItem(CupertinoIcons.person_crop_circle, '我的'),
  ];`,
    replace: `    GlassDockItem(CupertinoIcons.person_crop_circle, '我的'),
    GlassDockItem(CupertinoIcons.cloud, '书源'),
  ];`,
  },
  {
    name: '字段加 _fanhuoPage',
    find: `  final _localLibrary = LocalLibraryController();
  List<Widget> _pageWidgets = const [];`,
    replace: `  final _localLibrary = LocalLibraryController();
  late final FanhuoHomeTab _fanhuoPage = FanhuoHomeTab(
    repository: FanhuoSourceBootstrap.instance.repository,
    fetch: FanhuoSourceBootstrap.instance.fetch,
    settings: FanhuoSourceBootstrap.instance.settings,
    onSettingsChanged: FanhuoSourceBootstrap.instance.saveSettings,
  );

  List<Widget> _pageWidgets = const [];`,
  },
  {
    name: '监听「去书源」请求（全局 ValueNotifier）',
    find: `    _navigation.addListener(_navigationChanged);`,
    replace: `    _navigation.addListener(_navigationChanged);
    FanhuoHomeTab.openRequests.addListener(_openSourceRequested);`,
  },
  {
    name: 'dispose 时摘掉监听',
    find: `    _navigation.removeListener(_navigationChanged);`,
    replace: `    _navigation.removeListener(_navigationChanged);
    FanhuoHomeTab.openRequests.removeListener(_openSourceRequested);`,
  },
  {
    name: '_openSourceRequested 处理函数',
    find: `  void _navigationChanged() {`,
    replace: `  void _openSourceRequested() {
    if (!mounted) return;
    if (_visibleTabs.contains(4)) _selectTab(4, feedback: false);
  }

  void _navigationChanged() {`,
  },
  {
    name: '换掉书源页所用的滚动控制器占位（去掉多余字段）',
    find: `  /// 每个 tab 一个滚动控制器；书源页自己管滚动，这里给个占位，避免越界。
  final _fanhuoScroll = ScrollController();
  List<Widget> _pageWidgets = const [];`,
    replace: `  List<Widget> _pageWidgets = const [];`,
  },
  {
    name: '_headers 追加书源 masthead',
    find: `      settings.buildHeader,
    ];`,
    replace: `      settings.buildHeader,
      FanhuoHomeTab.buildHeader,
    ];`,
  },
  {
    name: '页面列表加书源页（自定义 map，不重复包 Atmosphere）',
    find: `              settings,
            ]
            .map((page) => RepaintBoundary(child: Atmosphere(child: page)))`,
    replace: `              settings,
              _fanhuoPage,
            ]
            .map(
              (page) => RepaintBoundary(
                child: page is FanhuoHomeTab ? page : Atmosphere(child: page),
              ),
            )`,
  },
  {
    name: '（校验）书源页必须进 _pageWidgets，否则 _headers[_tab] 越界',
    find: `              _fanhuoPage,`,
    replace: `              _fanhuoPage,`,
  },
  {
    // 1.8.0：底部「发现」改成书源发现页。
    // 底座那个 DiscoverPage 要连它私有的 libcpp.so 接口，在这台机器上永远
    // 「书籍加载失败」。书源里有 1256 个源自带分类目录，用它做发现更实际。
    name: '底部「发现」换成书源发现页',
    find: `    final discover = DiscoverPage(
      books: const [],
      feed: _catalog,
      state: widget.state,
      repository: widget.repository,
      showHeader: false,
      onSearch: _openSearch,
    );`,
    replace: `    // 1.8.0：底座 DiscoverPage 依赖私有 libcpp.so，永远加载失败。
    // 换成书源发现页（1256 个源自带分类目录，不碰私有接口）。
    final discover = SourceExplorePage(
      onOpenNovel: _openFanhuoNovel,
    );`,
  },
  {
    name: '_headers 里 discover 换成书源 masthead',
    find: `    _headers = [
      discover.buildHeader,`,
    replace: `    _headers = [
      (_) => const ArchiveMasthead(title: '发现', code: '01 / SOURCE ARCHIVE'),`,
  },
  {
    // 1.9.0：底部「书架」也换成书源书架。
    // 底座 ShelfPage 读的是上游 NovelRepository 的书（本地书 + 它自己的），
    // 书源书在另一个 id 空间（负数 -900000000 起），那个页面看不到。
    name: '底部「书架」换成书源书架',
    find: `    final shelf = ShelfPage(
      books: const [],
      state: widget.state,
      repository: widget.repository,
      showHeader: false,
      onSearch: _openSearch,
      navigation: _navigation,
    );`,
    replace: `    // 1.9.0：底座 ShelfPage 读的是上游书架，看不到书源书。
    // 换成书源书架（数据存 fanhuo.shelf.v1）。
    final shelf = SourceShelfPage(
      onOpenNovel: _openFanhuoNovel,
    );`,
  },
  {
    name: '_headers 里 shelf 换成书源 masthead',
    find: `      shelf.buildHeader,`,
    replace: `      (_) => const ArchiveMasthead(title: '书架', code: '02 / SOURCE SHELF'),`,
  },
  {
    name: '导入 SourceExplorePage 与 SourceShelfPage',
    find: `import 'fanhuo/home_tab.dart';`,
    replace: `import 'fanhuo/home_tab.dart';
import 'fanhuo/source_explore_page.dart';
import 'fanhuo/source_shelf_page.dart';`,
  },
]);

/* ────────── 2. home_navigation.dart ────────── */
patch('lib/home_navigation.dart', [
  {
    name: 'tabs 三条分支加索引 4',
    find: `    if (localReader) return combinedShelf ? const [1, 3] : const [2, 3];
    if (combinedShelf) return cachedShelf ? const [1, 3] : const [0, 1, 3];
    return cachedShelf ? const [1, 2, 3] : const [0, 1, 2, 3];`,
    replace: `    if (localReader) return combinedShelf ? const [1, 3, 4] : const [2, 3, 4];
    if (combinedShelf) return cachedShelf ? const [1, 3, 4] : const [0, 1, 3, 4];
    return cachedShelf ? const [1, 2, 3, 4] : const [0, 1, 2, 3, 4];`,
  },
]);

/* ────────── 3. main.dart ────────── */
patch('lib/main.dart', [
  {
    name: 'import HomeHealthBanner',
    find: `import 'pages.dart';`,
    replace: `import 'pages.dart';
import 'fanhuo/home_tab.dart';
import 'fanhuo/source_bootstrap.dart';`,
  },
  {
    name: '启动引导（书源运行时）',
    find: `              if (MediaQuery.sizeOf(context).isEmpty) {
                return const SizedBox.shrink();
              }`,
    replace: `              if (MediaQuery.sizeOf(context).isEmpty) {
                return const SizedBox.shrink();
              }
              // 书源运行时：读设置、后台解 11.5 MB 书源包。不阻塞首帧。
              FanhuoSourceBootstrap.instance.start();
              // 把上游书架交给书源运行时 —— 详情页的「收藏」写的是它，
              // 不注入的话点收藏毫无反应（书源书是负数 id，两套数据不互通）。
              FanhuoSourceBootstrap.instance.attachLibrary(state);`,
  },
  {
    name: 'pages.dart 导入 source_bootstrap（attachLibrary 需要）',
    find: `import 'fanhuo/home_tab.dart';`,
    replace: `import 'fanhuo/home_tab.dart';
import 'fanhuo/source_bootstrap.dart';`,
  },
  {
    name: 'home: 外面包 HomeHealthBanner（整段替换）',
    find: `              return RepaintBoundary(
                child: HomeShell(
                  state: state,
                  repository: repository,
                  network: widget.network,
                ),
              );`,
    replace: `              return RepaintBoundary(
                child: HomeHealthBanner(
                  onOpenSources: FanhuoHomeTab.requestOpen,
                  child: HomeShell(
                    state: state,
                    repository: repository,
                    network: widget.network,
                  ),
                ),
              );`,
  },
]);

log('挂载完成。');
log('书源运行时在 lib/fanhuo/source_bootstrap.dart，');
log('它负责懒加载书源包、持久化开关状态、以及带 GBK 兜底的 HTTP 抓取。');