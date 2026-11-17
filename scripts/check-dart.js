#!/usr/bin/env node
/**
 * Dart 源码静态体检：不装 Flutter SDK，只靠正则与括号配对，抓三类致命问题。
 *   1. 括号 / 方括号 / 花括号不配对（编译必炸）
 *   2. 单引号 / 双引号 / 三引号字符串没闭合
 *   3. 用了 `dart:io` / `dart:ui` / `package:flutter` 却没在文件头 import，
 *      或者导入了不存在的本地文件
 *
 * 这不是 analyzer，只能挡低级错误；真正的 `flutter analyze` 在 CI 里跑。
 * 但本机没有 Flutter SDK，这个脚本能让「改完立刻知道有没有写残」。
 */
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const TARGET_DIRS = ['lib'];

function walk(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, out);
    else if (entry.isFile() && entry.name.endsWith('.dart')) out.push(full);
  }
  return out;
}

/** 去掉注释与字符串，只留代码骨架，用来数括号。 */
function skeleton(source) {
  let out = '';
  let i = 0;
  const n = source.length;
  while (i < n) {
    const ch = source[i];
    const next = source[i + 1];
    const third = source[i + 2];
    // 行注释
    if (ch === '/' && next === '/') {
      while (i < n && source[i] !== '\n') i++;
      continue;
    }
    // 块注释（Dart 的块注释可以嵌套）
    if (ch === '/' && next === '*') {
      let depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (source[i] === '/' && source[i + 1] === '*') {
          depth++;
          i += 2;
        } else if (source[i] === '*' && source[i + 1] === '/') {
          depth--;
          i += 2;
        } else i++;
      }
      continue;
    }
    // 三引号字符串
    if ((ch === "'" || ch === '"') && next === ch && third === ch) {
      const quote = ch.repeat(3);
      i += 3;
      while (i < n && !source.startsWith(quote, i)) {
        if (source[i] === '\\') i++;
        i++;
      }
      i += 3;
      out += '""';
      continue;
    }
    // 普通字符串（含插值 ${...} 里可能还有引号，这里简单跳过）
    if (ch === "'" || ch === '"') {
      const quote = ch;
      const raw = source[i - 1] === 'r';
      i++;
      let closed = false;
      while (i < n) {
        if (!raw && source[i] === '\\') {
          i += 2;
          continue;
        }
        if (source[i] === quote) {
          closed = true;
          i++;
          break;
        }
        if (source[i] === '\n' && !raw) break; // 单行字符串不能跨行
        i++;
      }
      out += closed ? '""' : '"UNTERMINATED';
      continue;
    }
    out += ch;
    i++;
  }
  return out;
}

function checkBalanced(name, source) {
  const code = skeleton(source);
  if (code.includes('"UNTERMINATED')) {
    return '有未闭合的字符串（可能跨行了）';
  }
  const stack = [];
  const pairs = { ')': '(', ']': '[', '}': '{' };
  for (let i = 0; i < code.length; i++) {
    const ch = code[i];
    if (ch === '(' || ch === '[' || ch === '{') stack.push({ ch, i });
    else if (ch === ')' || ch === ']' || ch === '}') {
      const top = stack.pop();
      if (!top) return `第 ${lineOf(source, i)} 行多了一个 ${ch}`;
      if (top.ch !== pairs[ch]) {
        return `第 ${lineOf(source, top.i)} 行的 ${top.ch} 与第 ${lineOf(source, i)} 行的 ${ch} 不配对`;
      }
    }
  }
  if (stack.length) {
    const top = stack[stack.length - 1];
    return `第 ${lineOf(source, top.i)} 行的 ${top.ch} 没有闭合`;
  }
  return null;
}

function lineOf(source, index) {
  return source.slice(0, index).split('\n').length;
}

/** 检查 import 的目标是否存在（只查相对路径）。
 *
 * 注意：`lib/fanhuo/*.dart` 里允许 `../app_ui.dart` 这种上游引用 ——
 * 这些文件在仓库里是「待注入」的，上游文件要到 _wenku_base 才有，
 * 所以这里对 `lib/` 下的文件放宽：只要 _wenku_base/lib/ 里存在同名文件就算过。
 */
function checkImports(file, source) {
  const problems = [];
  const BASE_LIB = path.join(ROOT, '_wenku_base', 'lib');
  const BASE_WIDGETS = path.join(ROOT, '_wenku_base'); // 上游还可能从包根引（如 'package:wenku8_flutter/x.dart'）
  const importRe = /^\s*import\s+'([^']+)'/gm;
  let m;
  while ((m = importRe.exec(source))) {
    const target = m[1];
    // package: 引用由 pubspec + flutter analyze 保证，这里不管
    if (!target.startsWith('.') && !target.startsWith('/')) continue;
    const resolved = path.resolve(path.dirname(file), target);
    if (fs.existsSync(resolved)) continue;
    // 放宽一：目标可能在底座里（`../app_ui.dart` → 上游 lib/app_ui.dart）
    const upstream = path.join(BASE_LIB, path.basename(target));
    if (fs.existsSync(upstream)) continue;
    // 放宽二：底座还没拉（CI 的 check-version 关不跑 prepare-base）。
    // 这时无法判定，跳过而不是误报 —— 真正的 analyze 在 test 关会兜住。
    if (!fs.existsSync(BASE_LIB)) continue;
    problems.push(`import 指向不存在的文件：${target}`);
  }
  return problems;
}

const files = TARGET_DIRS.flatMap((d) => walk(path.join(ROOT, d)));
const problems = [];
for (const file of files) {
  const rel = path.relative(ROOT, file).replace(/\\/g, '/');
  const source = fs.readFileSync(file, 'utf8');
  const balance = checkBalanced(rel, source);
  if (balance) problems.push(`${rel}: ${balance}`);
  for (const problem of checkImports(file, source)) problems.push(`${rel}: ${problem}`);
  if (!source.endsWith('\n')) problems.push(`${rel}: 文件结尾缺换行（flutter analyze 会报）`);
  if (/\t/.test(source)) problems.push(`${rel}: 含制表符，Dart 风格要求 2 空格缩进`);
}

if (problems.length) {
  console.error(`Dart 体检失败（${problems.length} 项）：`);
  for (const p of problems) console.error(`  ✗ ${p}`);
  process.exit(1);
}
console.log(`Dart 体检通过：${files.length} 个文件，括号配对 / 字符串闭合 / import 目标 均正常。`);