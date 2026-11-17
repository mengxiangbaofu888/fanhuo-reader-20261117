#!/usr/bin/env node
/**
 * 把「书源搜到的书」接到上游阅读器（挂法：书源页 → 详情/阅读）。
 *
 * 这个脚本做的事有限且明确：让书源页的「加入书架 / 阅读」按钮真的能打开阅读页。
 * 它不改阅读器本身，只把 `FanhuoSourceRepository`（实现上游 `NovelRepository`）
 * 和 `openDetail` 串起来。
 *
 * 三个挂点：
 *   1. `lib/fanhuo/source_bootstrap.dart` 暴露 `novelRepository`（书源 → Novel 适配器）
 *   2. `lib/fanhuo/home_tab.dart` 的 `FanhuoHome` 接上 `onOpenBook`
 *   3. `lib/fanhuo/fanhuo_home.dart` 把这个回调传给搜索页
 *
 * 为什么不全自动：`openDetail` 需要 `BuildContext` + `LibraryState`，
 * 这两个东西只有 `HomeShell` 里有。所以 `FanhuoHomeTab` 多收一个
 * `onOpenNovel` 回调，由 `HomeShell` 在构造时注入。
 */
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const BASE = process.env.WENKU_BASE || path.join(ROOT, '_wenku_base');

function log(msg) {
  console.log(`[patch-reader] ${msg}`);
}
function fail(msg, hint) {
  console.error(`[patch-reader] ${msg}`);
  if (hint) console.error(`           ${hint}`);
  process.exit(1);
}
function must(rel) {
  const p = path.join(BASE, rel);
  if (!fs.existsSync(p)) fail(`底座缺文件：${rel}`);
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
  for (const { name, find, replace } of anchors) {
    if (text.includes(replace)) {
      log(`${rel}: ${name}（已应用，跳过）`);
      continue;
    }
    if (!text.includes(find)) {
      if (text.includes(name)) {
        log(`${rel}: ${name}（已应用，跳过）`);
        continue;
      }
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

/* ────────── HomeShell 注入 onOpenNovel ────────── */
patch('lib/pages.dart', [
  {
    name: 'HomeShell 构造时给书源页注入「打开阅读页」',
    find: `  late final FanhuoHomeTab _fanhuoPage = FanhuoHomeTab(
    repository: FanhuoSourceBootstrap.instance.repository,
    fetch: FanhuoSourceBootstrap.instance.fetch,
    settings: FanhuoSourceBootstrap.instance.settings,
    onSettingsChanged: FanhuoSourceBootstrap.instance.saveSettings,
  );`,
    replace: `  late final FanhuoHomeTab _fanhuoPage = FanhuoHomeTab(
    repository: FanhuoSourceBootstrap.instance.repository,
    fetch: FanhuoSourceBootstrap.instance.fetch,
    settings: FanhuoSourceBootstrap.instance.settings,
    onSettingsChanged: FanhuoSourceBootstrap.instance.saveSettings,
    onOpenNovel: _openFanhuoNovel,
  );`,
  },
  {
    name: '_openFanhuoNovel：书源书 → 上游详情/阅读',
    find: `  void _openSourceRequested() {`,
    replace: `  /// 书源搜到的书交给上游：先登记成 Novel，再走 openDetail。
  ///
  /// 直接用书源仓库作为 repository，这样上游的目录缓存、正文缓存、
  /// 阅读进度全部按负 id 正常落到本地。
  Future<void> _openFanhuoNovel(Novel novel) async {
    if (!mounted) return;
    final repository = FanhuoSourceBootstrap.instance.novelRepository;
    if (repository == null) return;
    openDetail(context, novel, widget.state, repository);
  }

  void _openSourceRequested() {`,
  },
]);

/* ────────── home_tab.dart 收下这个回调 ────────── */
patch('lib/fanhuo/home_tab.dart', [
  {
    name: 'import Novel',
    find: `import '../app_ui.dart';`,
    replace: `import '../app_ui.dart';
import '../catalog.dart';`,
  },
  {
    name: 'FanhuoHomeTab 增加 onOpenNovel 参数',
    find: `    required this.onSettingsChanged,
    this.onToggleSource,
  });`,
    replace: `    required this.onSettingsChanged,
    this.onToggleSource,
    this.onOpenNovel,
  });`,
  },
  {
    name: 'FanhuoHomeTab 字段',
    find: `  final Future<bool> Function(dynamic source, bool enabled)? onToggleSource;`,
    replace: `  final Future<bool> Function(dynamic source, bool enabled)? onToggleSource;

  /// 用户点「加入书架/阅读」时，把这本书记成上游 Novel 并交给阅读页。
  final Future<void> Function(Novel novel)? onOpenNovel;`,
  },
  {
    name: '把回调传给 FanhuoHome',
    find: `          settings: settings,
          onSettingsChanged: onSettingsChanged,
          onToggleSource: onToggleSource,
        ),`,
    replace: `          settings: settings,
          onSettingsChanged: onSettingsChanged,
          onToggleSource: onToggleSource,
          onOpenNovel: onOpenNovel,
        ),`,
  },
]);

/* ────────── fanhuo_home.dart 继续往下传 ────────── */
patch('lib/fanhuo/fanhuo_home.dart', [
  {
    name: 'import Novel 与书源仓库',
    find: `import 'fanqie_panel.dart';`,
    replace: `import '../catalog.dart';
import 'fanqie_panel.dart';`,
  },
  {
    name: 'FanhuoHome 增加 onOpenNovel',
    find: `    this.onOpenSearch,
    this.onToggleSource,
  });`,
    replace: `    this.onOpenSearch,
    this.onToggleSource,
    this.onOpenNovel,
  });`,
  },
  {
    name: 'FanhuoHome 字段',
    find: `  final Future<bool> Function(BookSourceLike source, bool enabled)? onToggleSource;`,
    replace: `  final Future<bool> Function(BookSourceLike source, bool enabled)? onToggleSource;

  /// 书源书 → 上游阅读页。
  final Future<void> Function(Novel novel)? onOpenNovel;`,
  },
  {
    name: '搜书卡片走书源搜索页（带上 onOpenNovel）',
    find: `                onTap: widget.onOpenSearch ??
                    () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => SourceManagerPage(
                              repository: widget.repository,
                              onToggle: widget.onToggleSource,
                            ),
                          ),
                        ),`,
    replace: `                onTap: widget.onOpenSearch ??
                    () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => SourceSearchPage(
                              repository: widget.repository,
                              fetch: widget.fetch,
                              onOpenNovel: widget.onOpenNovel,
                            ),
                          ),
                        ),`,
  },
  {
    name: 'import SourceSearchPage',
    find: `import 'source_manager_page.dart';`,
    replace: `import 'source_manager_page.dart';
import 'source_search_page.dart';`,
  },
]);

log('阅读链接入完成。');
log('链路：书源搜索页 → 点书 → FanhuoSourceRepository.bind → openDetail → 上游阅读器');