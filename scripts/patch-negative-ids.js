#!/usr/bin/env node
/**
 * 让上游接受负数 id（书源书用 -900000000 起的负 id）。
 *
 * 底座的 `NovelRepository` / `LibraryState` / `OfflineCacheStore` 里到处写着
 * `if (id <= 0) return;` —— 那是「本地书与上游书都是正数」年代的保护。
 * 书源书全部是负数，于是：
 *   - 详情页点「收藏」毫无反应（setShelfMembership 直接 return）
 *   - 离线缓存不落地（saveBook 抛 ArgumentError）
 *   - 阅读进度不记（rememberProgress 直接 return）
 *
 * 这个脚本把那些守卫从 `id <= 0` 改成 `id == 0`（0 才是真的无效 id）。
 *
 * ⚠️ 不能无脑全替换：第 179/205/241 行那几处是**章节 id**（`cid <= 0`），
 * 章节序号从 1 起，那个守卫是对的，必须保留。
 *
 * 幂等：每个文件处理前先看是否已含 `id == 0` + 我们的注释标记。
 */
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const BASE = process.env.WENKU_BASE || path.join(ROOT, '_wenku_base');

function log(msg) {
  console.log(`[neg-ids] ${msg}`);
}

/**
 * 精确替换表：只改「书籍 id」的守卫，不改章节 id。
 * key = 文件，value = [原文, 替换文] 数组。
 */
const PATCHES = {
  'lib/library_state.dart': [
    // 书架写盘
    [
      `    if (id == 0) return;`,
      `    if (id == 0) return;`,
    ],
  ],
};

/** 通用规则：把 `if (X.id <= 0)` / `if (id <= 0 ...)` 里明显是书籍 id 的改成 `== 0`。 */
const BOOK_ID_PATTERNS = [
  // if (novel.id <= 0)  → if (novel.id == 0)
  [/(\bnovel\.id\s*)<=\s*0/g, '$1== 0'],
  // if (id <= 0 || ...) 出现在非章节上下文——靠行内是否含 cid/chapter 排除
];

const TARGETS = [
  'lib/library_state.dart',
  'lib/offline_cache.dart',
  'lib/pages.dart',
];

function processFile(rel) {
  const file = path.join(BASE, rel);
  if (!fs.existsSync(file)) {
    log(`${rel} 不存在，跳过`);
    return 0;
  }
  let text = fs.readFileSync(file, 'utf8');
  const before = text;
  const lines = text.split('\n');
  let changed = 0;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // 跳过注释行（否则把我们自己写的说明文字也改了）
    if (/^\s*(\/\/|\*|\/\*)/.test(line)) continue;
    // 跳过章节 id 相关的行（cid / chapter）
    if (/\bcid\b|\bchapter\b|\bchapterId\b/i.test(line)) continue;
    if (!/id\s*<=\s*0/.test(line)) continue;

    // novel.id <= 0 → novel.id == 0
    let next = line.replace(/(\bnovel\.id\s*)<=\s*0/g, '$1== 0');
    // 裸 id <= 0（书籍上下文，前面已排除 cid/chapter）
    next = next.replace(/(?<![.\w])id\s*<=\s*0/g, 'id == 0');

    if (next !== line) {
      lines[i] = next;
      changed++;
      log(`${rel}:${i + 1}  ${line.trim()}  →  ${next.trim()}`);
    }
  }

  if (changed > 0) {
    fs.writeFileSync(file, lines.join('\n'), 'utf8');
  }
  return changed;
}

let total = 0;
for (const rel of TARGETS) {
  total += processFile(rel);
}
log(total === 0 ? '没有需要改的守卫（可能已应用）' : `共改 ${total} 处`);