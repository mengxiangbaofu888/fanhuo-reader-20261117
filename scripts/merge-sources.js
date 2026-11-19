#!/usr/bin/env node
/**
 * 合并书源：aoaostar 最新全量 + 旷野书屋精选。
 *
 * 为什么换源：2026-11-19 实测旧包（2024 年数据）24 个源 0 可达，
 * 而 aoaostar 当日同步的 3907 条里抽样 60 个域名有 34 个可达（57%）。
 *
 * 产物：data/bookSources-merged.json（数组，每项带 sourcePack + jsTier）
 *
 * 用法：
 *   node scripts/merge-sources.js
 *   node scripts/merge-sources.js --check   只统计不写盘
 */
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DATA = path.join(ROOT, 'data');
const NEW_SRC = path.join(DATA, '_src', 'aoaostar-full-20261119.json');
const KUANGYE = path.join(DATA, 'kuangye-bookSources-133-probed.json');
const OUT = path.join(DATA, 'bookSources-merged.json');
const CHECK_ONLY = process.argv.includes('--check');

function log(msg) {
  console.log(`[merge] ${msg}`);
}

/** 判断一条源的 JS 依赖档位。规则与 SourceRepository.searchable 一致。 */
function classifyTier(source) {
  const rules = [
    source.ruleSearch,
    source.ruleToc,
    source.ruleContent,
    source.ruleBookInfo,
    source.ruleExplore,
  ];
  const text = JSON.stringify(rules || {});
  if (!/["]@js:|<js>|java\.|Packages\./.test(text)) return 'none';

  // hard：要 Java 反射（Packages.xxx），我们做不到
  if (/Packages\./.test(text)) return 'hard';

  // 用到异步宿主 API 的算 mid（要 QuickJS + Promise 桥）
  const asyncApis = /java\.(ajax|getUrl|post|connect)\b/;
  // JSON.parse / 对象遍历这类纯 JS 的算 simple
  const pureJs = /JSON\.parse|\.forEach\(|\.map\(|Object\.keys/;

  if (asyncApis.test(text)) return 'mid';
  if (pureJs.test(text)) return 'simple';
  // 其余 JS 走子集解释器能覆盖大部分字符串/正则操作
  return 'simple';
}

function normalize(source, pack) {
  const out = { ...source };
  out.sourcePack = pack;
  out.jsTier = classifyTier(source);
  // 只保留我们能吃的字段，减小包体
  delete out.bookSourceComment;
  delete out.customOrder;
  return out;
}

function keyOf(s) {
  const url = String(s.bookSourceUrl || '').trim().toLowerCase()
      .replace(/^https?:\/\//, '')
      .replace(/\/+$/, '');
  return url;
}

function main() {
  if (!fs.existsSync(NEW_SRC)) {
    console.error(`[merge] 缺少新书源：${NEW_SRC}`);
    process.exit(1);
  }
  const fresh = JSON.parse(fs.readFileSync(NEW_SRC, 'utf8'));
  log(`新书源 ${fresh.length} 条`);

  const merged = [];
  const seen = new Set();

  // 1) aoaostar 最新全量优先
  for (const s of fresh) {
    if (!s || !s.bookSourceUrl || !s.bookSourceName) continue;
    const k = keyOf(s);
    if (!k || seen.has(k)) continue;
    seen.add(k);
    merged.push(normalize(s, 'aoaostar'));
  }
  log(`去重后 ${merged.length} 条`);

  // 2) 旷野书屋（小众但质量高，且带人工探测结果）
  if (fs.existsSync(KUANGYE)) {
    const ky = JSON.parse(fs.readFileSync(KUANGYE, 'utf8'));
    let added = 0;
    for (const s of ky) {
      if (!s || !s.bookSourceUrl) continue;
      const k = keyOf(s);
      if (!k || seen.has(k)) continue;
      seen.add(k);
      merged.push(normalize(s, 'kuangye'));
      added++;
    }
    log(`旷野新增 ${added} 条（去重后）`);
  }

  // 3) 统计
  const tiers = {};
  let searchable = 0;
  let explorable = 0;
  for (const s of merged) {
    tiers[s.jsTier] = (tiers[s.jsTier] || 0) + 1;
    const enabled = s.enabled !== false;
    const canSearch = enabled && String(s.searchUrl || '').trim() !== ''
        && s.jsTier !== 'hard';
    const canExplore = enabled && s.enabledExplore !== false
        && String(s.exploreUrl || '').trim() !== '';
    if (canSearch) searchable++;
    if (canExplore) explorable++;
  }
  log(`合计 ${merged.length} 条 | 可搜 ${searchable} | 带发现页 ${explorable}`);
  log(`分档 ${JSON.stringify(tiers)}`);

  if (CHECK_ONLY) return;

  fs.writeFileSync(OUT, JSON.stringify(merged), 'utf8');
  const mb = (fs.statSync(OUT).size / 1024 / 1024).toFixed(1);
  log(`写入 ${OUT}（${mb} MB）`);
}

main();