#!/usr/bin/env node
/**
 * 拉底座 + 注入补丁 + 灌入一个「番茄阅读页」示例 patch（幂等）。
 * 补齐底座源码后，用这个脚本把 lib/fanhuo/ 下的新文件拷进去。
 */
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const BASE = path.join(ROOT, '_wenku_base');
const SRC = path.join(ROOT, 'lib', 'fanhuo');

function copyTree(from, to) {
  fs.mkdirSync(to, { recursive: true });
  for (const entry of fs.readdirSync(from, { withFileTypes: true })) {
    const src = path.join(from, entry.name);
    const dst = path.join(to, entry.name);
    if (entry.isDirectory()) copyTree(src, dst);
    else {
      fs.copyFileSync(src, dst);
      console.log(`  + lib/fanhuo/${path.relative(SRC, src).replace(/\\/g, '/')}`);
    }
  }
}

if (!fs.existsSync(path.join(BASE, 'pubspec.yaml'))) {
  console.error('先跑 scripts/prepare-base.js');
  process.exit(1);
}
if (!fs.existsSync(SRC)) {
  console.error('lib/fanhuo/ 不存在');
  process.exit(1);
}
copyTree(SRC, path.join(BASE, 'lib', 'fanhuo'));
console.log('完成：lib/fanhuo/ 已就位');