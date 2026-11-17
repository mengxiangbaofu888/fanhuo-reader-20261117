#!/usr/bin/env node
/**
 * 并发探测书源首页可达性，把结果写回 data/kuangye-bookSources-133-probed.json 的 probeStatus。
 *   node scripts/probe-sources.js            全部探
 *   node scripts/probe-sources.js --limit 20 只探前 20 条
 *   node scripts/probe-sources.js --concurrency 16
 *
 * probeStatus 取值：HTTP 状态码，或 000 表示连接失败/超时。
 * 注意：200 只代表「首页能打开」，不代表「能搜到书」。
 */
'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');

const ROOT = path.resolve(__dirname, '..');
const DATA = path.join(ROOT, 'data', 'kuangye-bookSources-133-probed.json');

function argNum(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1) return fallback;
  const v = Number(process.argv[i + 1]);
  return Number.isFinite(v) ? v : fallback;
}
const LIMIT = argNum('limit', Infinity);
const CONCURRENCY = Math.max(1, argNum('concurrency', 12));
const TIMEOUT = argNum('timeout', 10000);

function probe(url) {
  return new Promise((resolve) => {
    let settled = false;
    const done = (code) => {
      if (settled) return;
      settled = true;
      resolve(code);
    };
    let target;
    try {
      target = new URL(url);
    } catch {
      return done(0);
    }
    const mod = target.protocol === 'https:' ? https : http;
    const req = mod.request(
      {
        protocol: target.protocol,
        hostname: target.hostname,
        port: target.port || undefined,
        path: target.pathname + target.search,
        method: 'GET',
        headers: {
          'User-Agent':
            'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile Safari/537.36',
          Accept: 'text/html,application/xhtml+xml',
        },
        timeout: TIMEOUT,
        rejectUnauthorized: false, // 书源站证书五花八门，只要能拿到页面就算可达
      },
      (res) => {
        res.resume();
        done(res.statusCode || 0);
      },
    );
    req.on('timeout', () => {
      req.destroy();
      done(0);
    });
    req.on('error', () => done(0));
    req.end();
  });
}

async function runPool(items, worker, concurrency) {
  const results = new Array(items.length);
  let cursor = 0;
  const lanes = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (true) {
      const index = cursor++;
      if (index >= items.length) return;
      results[index] = await worker(items[index], index);
      const done = results.filter((r) => r !== undefined).length;
      process.stdout.write(`\r已探测 ${done}/${items.length}`);
    }
  });
  await Promise.all(lanes);
  process.stdout.write('\n');
  return results;
}

(async () => {
  const sources = JSON.parse(fs.readFileSync(DATA, 'utf8'));
  const targets = sources.slice(0, LIMIT);
  console.log(`并发 ${CONCURRENCY}，超时 ${TIMEOUT}ms，共 ${targets.length} 个源`);

  const statuses = await runPool(targets, (s) => probe(s.bookSourceUrl), CONCURRENCY);

  targets.forEach((s, i) => {
    s.probeStatus = String(statuses[i] || 0);
  });

  const tally = {};
  for (const s of targets) tally[s.probeStatus] = (tally[s.probeStatus] || 0) + 1;
  console.log('状态分布：', tally);

  fs.writeFileSync(DATA, JSON.stringify(sources, null, 2), 'utf8');
  console.log(`已写回 ${path.relative(ROOT, DATA)}`);
})();