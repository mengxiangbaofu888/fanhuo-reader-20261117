#!/usr/bin/env node
/**
 * 版本号工具。
 *   node scripts/bump-version.js            看当前版本
 *   node scripts/bump-version.js patch      1.0.0 -> 1.0.1
 *   node scripts/bump-version.js minor      1.0.0 -> 1.1.0
 *   node scripts/bump-version.js major      1.0.0 -> 2.0.0
 *   node scripts/bump-version.js 1.2.3      直接指定
 */
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const VERSION_FILE = path.join(ROOT, 'VERSION');
const BASE_PUBSPEC = path.join(ROOT, '_wenku_base', 'pubspec.yaml');

function readVersion() {
  return fs.readFileSync(VERSION_FILE, 'utf8').trim();
}
function versionCode(v) {
  const [a, b, c] = v.split('.').map(Number);
  return a * 10000 + b * 100 + c;
}
function writeVersion(v) {
  fs.writeFileSync(VERSION_FILE, v);
  // 底座存在时同步 pubspec.yaml 的 version
  if (fs.existsSync(BASE_PUBSPEC)) {
    let text = fs.readFileSync(BASE_PUBSPEC, 'utf8');
    const next = text.replace(/^version:\s*\S+\s*$/m, `version: ${v}+${versionCode(v)}`);
    if (next !== text) {
      fs.writeFileSync(BASE_PUBSPEC, next);
      console.log(`已同步 _wenku_base/pubspec.yaml → ${v}+${versionCode(v)}`);
    }
  }
}

const arg = (process.argv[2] || '').trim();
const current = readVersion();

if (!arg) {
  console.log(`当前版本：${current}（versionCode ${versionCode(current)}）`);
  process.exit(0);
}

let next;
if (/^\d+\.\d+\.\d+$/.test(arg)) {
  next = arg;
} else {
  const [a, b, c] = current.split('.').map(Number);
  if (arg === 'major') next = `${a + 1}.0.0`;
  else if (arg === 'minor') next = `${a}.${b + 1}.0`;
  else if (arg === 'patch') next = `${a}.${b}.${c + 1}`;
  else {
    console.error(`不认识的参数：${arg}（可用 patch / minor / major / x.y.z）`);
    process.exit(1);
  }
}

if (versionCode(next) <= versionCode(current)) {
  console.error(`新 versionCode ${versionCode(next)} 没有大于旧值 ${versionCode(current)}`);
  process.exit(1);
}

writeVersion(next);
console.log(`${current} -> ${next}（versionCode ${versionCode(next)}）`);
console.log('别忘了在 CHANGELOG.md 补一节：## [' + next + '] - ' + new Date().toISOString().slice(0, 10));