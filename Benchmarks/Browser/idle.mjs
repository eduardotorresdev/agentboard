import { webkit, devices } from 'playwright-core';
import { execSync, spawn } from 'node:child_process';
import fs from 'node:fs';
const W = process.env.HOME + '/Library/Caches/ms-playwright/webkit-2370';
const ctxFile = process.cwd() + '/contexts.txt'; fs.rmSync(ctxFile, { force: true });
const cpuTime = t => t.split(':').map(Number).reduce((a, v) => a * 60 + v, 0);
const sample = () => execSync('ps -A -o pid=,time=,rss=,command=').toString().split('\n').reduce((s, l) => { const m = l.trim().match(/^(\d+)\s+(\S+)\s+(\d+)\s+(.*)$/); if (m && (m[4].includes('ms-playwright/webkit') || m[4].includes('zc/embedder') || m[4].includes('zc/host'))) { s.cpu += cpuTime(m[2]); s.rss += Number(m[3]) / 1024; } return s; }, { cpu: 0, rss: 0 });
const zc = process.argv[2] === 'zc';
const browser = await webkit.launch(zc ? { executablePath: process.cwd() + '/embedder', env: { ...process.env, DYLD_FRAMEWORK_PATH: W, DYLD_LIBRARY_PATH: W, AB_CONTEXT_FILE: ctxFile } } : {});
const { heavy } = await import('./pages.mjs');
const hosts = [];
for (const n of [1, 3]) {
  const ctxs = [];
  for (let i = 0; i < n; i++) { const c = await browser.newContext({ ...devices['Desktop Safari'] }); const p = await c.newPage(); await p.setContent(heavy); ctxs.push(c); }
  await new Promise(r => setTimeout(r, 800));
  if (zc) for (const line of fs.readFileSync(ctxFile, 'utf8').trim().split('\n')) hosts.push(spawn('./host', [line.split(' ')[1], '0.4'], { stdio: 'ignore' }));
  await new Promise(r => setTimeout(r, 2500));
  const a = sample(), t = performance.now(); await new Promise(r => setTimeout(r, 6000)); const b = sample();
  console.log(zc ? 'zero-copy' : 'playwright headless', `${n} idle page(s)${zc ? ' hosted on screen' : ''}`, 'cpu', ((b.cpu - a.cpu) / ((performance.now() - t) / 1000) * 100).toFixed(1) + '%', 'rss', Math.round(b.rss), 'MB');
  hosts.splice(0).forEach(h => h.kill()); fs.rmSync(ctxFile, { force: true });
  for (const c of ctxs) await c.close();
}
await browser.close();
