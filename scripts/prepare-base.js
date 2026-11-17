#!/usr/bin/env node
/**
 * 拉 Wenku8_Flutter 底座源码到 _wenku_base/。
 * 两条路：
 *   1. codeload tarball（本机 github.com 可达时最快，28 MB 约 40 秒）
 *   2. git clone（tarball 不通时退路）
 * 都不通就直接报错退出，不做静默降级。
 */
'use strict';
const fs = require('fs');
const path = require('path');
const https = require('https');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const BASE_DIR = path.join(ROOT, '_wenku_base');
const REPO = process.env.WENKU_BASE_REPO || 'P5UEDGK/Wenku8_Flutter';
const REF = process.env.WENKU_BASE_REF || 'master';
const TARBALL = `https://codeload.github.com/${REPO}/tar.gz/refs/heads/${REF}`;

function log(msg) {
  console.log(`[prepare-base] ${msg}`);
}

function download(url, dest, redirects = 0) {
  return new Promise((resolve, reject) => {
    if (redirects > 5) return reject(new Error('重定向过多'));
    https
      .get(url, { headers: { 'User-Agent': 'fanhuo-reader-build' } }, (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          res.resume();
          return resolve(download(res.headers.location, dest, redirects + 1));
        }
        if (res.statusCode !== 200) {
          res.resume();
          return reject(new Error(`HTTP ${res.statusCode} ${url}`));
        }
        const total = Number(res.headers['content-length'] || 0);
        let got = 0;
        let lastTick = 0;
        const out = fs.createWriteStream(dest);
        res.on('data', (chunk) => {
          got += chunk.length;
          const now = Date.now();
          if (now - lastTick > 3000) {
            lastTick = now;
            const pct = total ? ((got / total) * 100).toFixed(1) + '%' : '?';
            log(`下载中 ${(got / 1048576).toFixed(1)} MB (${pct})`);
          }
        });
        res.pipe(out);
        out.on('finish', () => out.close(() => resolve(dest)));
        out.on('error', reject);
      })
      .on('error', reject);
  });
}

async function main() {
  if (fs.existsSync(path.join(BASE_DIR, 'pubspec.yaml'))) {
    log('底座已存在，跳过下载（想重拉先删 _wenku_base/）');
    return;
  }
  fs.mkdirSync(BASE_DIR, { recursive: true });
  const tarball = path.join(ROOT, '_wenku_base.tar.gz');

  let got = false;
  try {
    log(`通道 1：codeload tarball ${REPO}@${REF}`);
    await download(TARBALL, tarball);
    log(`已下载 ${(fs.statSync(tarball).size / 1048576).toFixed(1)} MB，解压…`);
    // Windows 10+ 自带 tar，Git for Windows 也有
    execFileSync('tar', ['-xzf', tarball, '-C', BASE_DIR, '--strip-components=1'], {
      stdio: 'inherit',
    });
    got = true;
  } catch (error) {
    log(`通道 1 失败：${error.message}`);
  }

  if (!got) {
    try {
      log('通道 2：git clone --depth 1');
      execFileSync('git', ['clone', '--depth', '1', '-b', REF, `https://github.com/${REPO}.git`, BASE_DIR], {
        stdio: 'inherit',
      });
      got = true;
    } catch (error) {
      log(`通道 2 失败：${error.message}`);
    }
  }

  if (!got) {
    console.error('[prepare-base] 两个通道都不通。检查网络，或手工把 Wenku8_Flutter 源码解压到 _wenku_base/');
    process.exit(1);
  }
  fs.rmSync(tarball, { force: true });
  const files = fs.readdirSync(BASE_DIR).length;
  log(`底座就绪：_wenku_base/ 共 ${files} 个顶层条目`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});