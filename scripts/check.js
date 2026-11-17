#!/usr/bin/env node
/**
 * 自检：不碰 Java，不联网，秒出。
 * 检查项：
 *   1. VERSION 格式与 CHANGELOG 是否有对应小节
 *   2. data/ 四个数据文件的条数与关键字段
 *   3. 仓库里是否有密钥泄漏（长 token / 私钥头 / key.properties）
 *   4. scripts/ 下所有 .js 语法可解析
 */
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..');
const fail = [];
const ok = [];

function read(p) {
  return fs.readFileSync(path.join(ROOT, p), 'utf8');
}
function exists(p) {
  return fs.existsSync(path.join(ROOT, p));
}

/* ---------- 1. 版本 ---------- */
const version = read('VERSION').trim();
if (!/^\d+\.\d+\.\d+$/.test(version)) {
  fail.push(`VERSION 不是 主.次.补：${version}`);
} else {
  ok.push(`VERSION = ${version}`);
}
const changelog = read('CHANGELOG.md');
if (!changelog.includes(`## [${version}]`)) {
  fail.push(`CHANGELOG.md 缺少 ## [${version}] 小节`);
} else {
  ok.push('CHANGELOG 有当前版本小节');
}
const [major, minor, patch] = version.split('.').map(Number);
const versionCode = major * 10000 + minor * 100 + patch;
ok.push(`versionCode = ${versionCode}`);

/* ---------- 2. 数据 ---------- */
const sources = JSON.parse(read('data/kuangye-bookSources-133-probed.json'));
if (!Array.isArray(sources)) fail.push('书源文件不是数组');
else {
  ok.push(`书源 ${sources.length} 条`);
  if (sources.length !== 133) fail.push(`书源数量应为 133，实际 ${sources.length}`);
  const withSearch = sources.filter((s) => s.searchUrl).length;
  ok.push(`带 searchUrl ${withSearch} 条`);
  if (withSearch !== 132) fail.push(`带 searchUrl 应为 132，实际 ${withSearch}`);
  const bad = sources.filter((s) => !s.bookSourceUrl || !s.bookSourceName);
  if (bad.length) fail.push(`${bad.length} 条书源缺 bookSourceUrl / bookSourceName`);
  const alive = sources.filter((s) => String(s.probeStatus) === '200').length;
  ok.push(`首页可达（200）${alive} 条`);
}

const presets = JSON.parse(read('data/fanqie-presets.json'));
if (!presets.papers || Object.keys(presets.papers).length !== 5) {
  fail.push('番茄预设应有 5 套正文底色');
} else ok.push(`番茄底色 5 套：${Object.keys(presets.papers).join('/')}`);
if (!Array.isArray(presets.pageTurnModes) || presets.pageTurnModes.length !== 4) {
  fail.push('番茄翻页应有 4 档');
} else ok.push('番茄翻页 4 档');

const providers = JSON.parse(read('data/ai-providers.json'));
if (!Array.isArray(providers.providers) || providers.providers.length < 10) {
  fail.push('AI 厂商目录不足 10 个');
} else ok.push(`AI 厂商 ${providers.providers.length} 个`);
const missingModel = providers.providers.filter(
  (p) => p.id !== 'custom' && p.id !== 'ollama' && !p.defaultModel,
);
if (missingModel.length) fail.push(`厂商缺 defaultModel：${missingModel.map((p) => p.id)}`);

/* ---------- 3. 密钥泄漏 ---------- */
const SECRET_PATTERNS = [
  [/gh[opsu]_[A-Za-z0-9]{20,}/, 'GitHub token'],
  [/sk-ant-[A-Za-z0-9_-]{20,}/, 'Anthropic key'],
  [/sk-[A-Za-z0-9]{32,}/, 'OpenAI 风格 key'],
  [/AIza[0-9A-Za-z_-]{30,}/, 'Google API key'],
  [/-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----/, '私钥'],
  [/xai-[A-Za-z0-9]{20,}/, 'xAI key'],
];
const SKIP_DIRS = new Set(['node_modules', '.git', '.dart_tool', 'build', 'dist', '_wenku_base', 'artifacts', '.pub-cache']);
function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      walk(path.join(dir, entry.name), out);
    } else if (entry.isFile()) {
      out.push(path.join(dir, entry.name));
    }
  }
  return out;
}
let scanned = 0;
for (const file of walk(ROOT)) {
  const rel = path.relative(ROOT, file).replace(/\\/g, '/');
  if (rel === 'scripts/check.js') continue; // 本文件的模式串是自证用的
  const size = fs.statSync(file).size;
  if (size > 4 * 1024 * 1024) continue;
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    continue;
  }
  scanned += 1;
  for (const [pattern, label] of SECRET_PATTERNS) {
    if (pattern.test(text)) fail.push(`疑似 ${label} 泄漏：${rel}`);
  }
  // 硬编码真实 key 的写法：apiKey = "长串"
  const hard = /(api[_-]?key|token|secret)\s*[:=]\s*["'][A-Za-z0-9_\-]{24,}["']/i.exec(text);
  if (hard) fail.push(`疑似硬编码密钥：${rel}`);
}
ok.push(`扫描 ${scanned} 个文本文件，无密钥泄漏`);
for (const banned of ['key.properties']) {
  if (exists(banned)) fail.push(`不应提交 ${banned}`);
}
for (const banned of ['.jks', '.keystore']) {
  const found = walk(ROOT).filter((f) => f.endsWith(banned));
  if (found.length) fail.push(`不应提交签名文件：${found.map((f) => path.relative(ROOT, f))}`);
}

/* ---------- 4. 脚本语法 ---------- */
for (const file of walk(path.join(ROOT, 'scripts'))) {
  if (!file.endsWith('.js')) continue;
  try {
    new vm.Script(fs.readFileSync(file, 'utf8'), { filename: file });
  } catch (error) {
    fail.push(`语法错误 ${path.relative(ROOT, file)}：${error.message}`);
  }
}
ok.push('scripts/*.js 语法通过');

/* ---------- 输出 ---------- */
for (const line of ok) console.log(`  ✓ ${line}`);
if (fail.length) {
  console.error('\n自检失败：');
  for (const line of fail) console.error(`  ✗ ${line}`);
  process.exit(1);
}
console.log(`\n全部通过（${ok.length} 项）。`);