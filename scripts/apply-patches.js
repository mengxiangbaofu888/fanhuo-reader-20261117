#!/usr/bin/env node
/**
 * 把本项目的数据与文件注入底座源码（_wenku_base/）。
 *
 * 幂等：重复跑结果一致。每个改动前先备份到 `_wenku_base/.backup/<时间戳>/`。
 *
 * 做五件事：
 *   1. 应用 patches/ 下的 .patch（unified diff，git apply）
 *   2. 拷 data/ 下的书源与配置到 assets/fanhuo/
 *   3. 拷 lib/fanhuo/ 到 _wenku_base/lib/fanhuo/
 *   4. 改 pubspec.yaml：flutter.assets 里加 assets/fanhuo/
 *   5. 改 android/app/build.gradle.kts：applicationId + 应用名
 *
 * 为什么不改 namespace：
 *   Kotlin 侧 MainActivity 等类的 `package` 是写死的 `org.mewx.wenku8_flutter`，
 *   AGP 按 namespace 找 `<namespace>.MainActivity`。改了 namespace 而不挪 Kotlin 目录，
 *   构建会在「找不到启动 Activity」上挂。所以 namespace 保持不动，
 *   只把 applicationId（安装包身份）改成 com.fanhuo.reader。
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const BASE = path.join(ROOT, '_wenku_base');
const BACKUP = path.join(BASE, '.backup');

const TARGET_APP_ID = 'com.fanhuo.reader';
const TARGET_LABEL = '番茄阅读 Pro';

function log(msg) {
  console.log(`[apply-patches] ${msg}`);
}
function must(rel) {
  const p = path.join(BASE, rel);
  if (!fs.existsSync(p)) {
    console.error(`[apply-patches] 底座缺文件：${rel}。先跑 scripts/prepare-base.js`);
    process.exit(1);
  }
  return p;
}
function backup(rel) {
  const src = path.join(BASE, rel);
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const dst = path.join(BACKUP, stamp, rel);
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.copyFileSync(src, dst);
}
function copyTree(from, to) {
  fs.mkdirSync(to, { recursive: true });
  for (const entry of fs.readdirSync(from, { withFileTypes: true })) {
    const src = path.join(from, entry.name);
    const dst = path.join(to, entry.name);
    if (entry.isDirectory()) copyTree(src, dst);
    else fs.copyFileSync(src, dst);
  }
}

if (!fs.existsSync(path.join(BASE, 'pubspec.yaml'))) {
  console.error('[apply-patches] 没有底座。先跑 scripts/prepare-base.js');
  process.exit(1);
}

/* ---------- 1. patches ---------- */
const patchDir = path.join(ROOT, 'patches');
const patches = fs.existsSync(patchDir)
  ? fs.readdirSync(patchDir).filter((f) => f.endsWith('.patch')).sort()
  : [];
if (!patches.length) {
  log('patches/ 为空，跳过补丁应用（本项目至今全是新增文件，用不着 patch）');
}
for (const name of patches) {
  log(`应用 ${name}`);
  try {
    execFileSync('git', ['apply', '--verbose', '--whitespace=nowarn', path.join(patchDir, name)], {
      cwd: BASE,
      stdio: 'inherit',
    });
  } catch {
    console.error(`[apply-patches] ${name} 打不上：底座被改过或版本漂移。删掉 _wenku_base/ 重拉底座再来。`);
    process.exit(1);
  }
}

/* ---------- 2. data → assets/fanhuo ---------- */
const assetDir = path.join(BASE, 'assets', 'fanhuo');
fs.mkdirSync(assetDir, { recursive: true });
for (const name of [
  'kuangye-bookSources-133-probed.json',
  'fanqie-presets.json',
  'ai-providers.json',
]) {
  const src = path.join(ROOT, 'data', name);
  if (!fs.existsSync(src)) {
    console.error(`[apply-patches] data/${name} 不存在`);
    process.exit(1);
  }
  fs.copyFileSync(src, path.join(assetDir, name));
  log(`data/${name} → assets/fanhuo/${name}`);
}

/* ---------- 3. lib/fanhuo → _wenku_base/lib/fanhuo ---------- */
const libSrc = path.join(ROOT, 'lib', 'fanhuo');
if (fs.existsSync(libSrc)) {
  const libDst = path.join(BASE, 'lib', 'fanhuo');
  const before = fs.existsSync(libDst) ? fs.readdirSync(libDst).length : 0;
  copyTree(libSrc, libDst);
  const after = fs.readdirSync(libDst).length;
  log(`lib/fanhuo/ → _wenku_base/lib/fanhuo/（${before} → ${after} 个文件）`);
}

/* ---------- 3.5 test/fanhuo → _wenku_base/test/fanhuo ---------- */
const testSrc = path.join(ROOT, 'test', 'fanhuo');
if (fs.existsSync(testSrc)) {
  const testDst = path.join(BASE, 'test', 'fanhuo');
  copyTree(testSrc, testDst);
  log(`test/fanhuo/ → _wenku_base/test/fanhuo/（${fs.readdirSync(testDst).length} 个文件）`);
}

/* ---------- 4. pubspec.yaml ---------- */
{
  const rel = 'pubspec.yaml';
  const file = must(rel);
  let text = fs.readFileSync(file, 'utf8');
  if (text.includes('    - assets/fanhuo/')) {
    log('pubspec.yaml 已含 assets/fanhuo/，跳过');
  } else {
    backup(rel);
    const marker = /^(\s*)assets:\s*$/m;
    const m = marker.exec(text);
    if (!m) {
      console.error('[apply-patches] pubspec.yaml 里找不到 flutter.assets 段，锚点失效');
      process.exit(1);
    }
    const indent = `${m[1]}  `;
    text = text.replace(marker, (whole) => `${whole}\n${indent}- assets/fanhuo/`);
    fs.writeFileSync(file, text);
    log('pubspec.yaml 注入 assets/fanhuo/');
  }
}

/* ---------- 5. build.gradle.kts ---------- */
{
  const rel = 'android/app/build.gradle.kts';
  const file = must(rel);
  const original = fs.readFileSync(file, 'utf8');
  let text = original;

  // 只改 applicationId，namespace 与 Kotlin 包名保持 org.mewx.wenku8_flutter
  const appIdRe = /(\n\s*applicationId\s*=\s*)"[^"]*"/;
  if (!appIdRe.test(text)) {
    console.error('[apply-patches] build.gradle.kts 里找不到 applicationId，锚点失效');
    process.exit(1);
  }
  text = text.replace(appIdRe, `$1"${TARGET_APP_ID}"`);

  const labelRe = /(\n\s*manifestPlaceholders\["wenkuAppLabel"\]\s*=\s*)"[^"]*"/;
  if (labelRe.test(text)) {
    text = text.replace(labelRe, `$1"${TARGET_LABEL}"`);
  }

  if (text !== original) {
    backup(rel);
    fs.writeFileSync(file, text);
    log(`build.gradle.kts：applicationId → ${TARGET_APP_ID}，应用名 → ${TARGET_LABEL}`);
  } else {
    log('build.gradle.kts 已是目标值，跳过');
  }

  const namespaceLine = /namespace\s*=\s*"([^"]+)"/.exec(text);
  if (namespaceLine && namespaceLine[1] !== `org.mewx.wenku8_flutter`) {
    log(`警告：namespace 被改成了 ${namespaceLine[1]}，Kotlin 包名没跟着挪就会找不到 MainActivity`);
  }
}

log('注入完成。');