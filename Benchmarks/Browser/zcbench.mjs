// Zero-copy path: our embedder renders natively; a host process shows the window's layer tree.
// Measures page frame rate (rAF gaps) and CPU of every process involved, per scenario.
import { webkit, devices } from 'playwright-core';
import { execSync, spawn } from 'node:child_process';
import fs from 'node:fs';
const W = process.env.HOME + '/Library/Caches/ms-playwright/webkit-2370';
const ctxFile = process.cwd() + '/contexts.txt'; fs.rmSync(ctxFile, { force: true });
const cpuTime = t => t.split(':').map(Number).reduce((a, v) => a * 60 + v, 0);
function sample() {
  const by = { webkit: 0, host: 0, node: 0 };
  for (const l of execSync('ps -A -o pid=,time=,command=').toString().split('\n')) {
    const m = l.trim().match(/^(\d+)\s+(\S+)\s+(.*)$/); if (!m) continue;
    const c = cpuTime(m[2]);
    if (Number(m[1]) === process.pid) by.node += c;
    else if (m[3].includes('zc/host')) by.host += c;
    else if (m[3].includes('ms-playwright/webkit') || m[3].includes('zc/embedder')) by.webkit += c;
  }
  return by;
}
const browser = await webkit.launch({ executablePath: process.cwd() + '/embedder', env: { ...process.env, DYLD_FRAMEWORK_PATH: W, DYLD_LIBRARY_PATH: W, AB_CONTEXT_FILE: ctxFile } });
const ctx = await browser.newContext({ ...devices['Desktop Safari'] });
const page = await ctx.newPage();
await page.waitForTimeout(600);
const cid = fs.readFileSync(ctxFile, 'utf8').trim().split(' ')[1];
const host = process.env.NO_HOST ? null : spawn('./host', [cid, process.env.SCALE ?? '0.5'], { stdio: 'ignore' });
await page.waitForTimeout(1000);

const { heavy } = await import('./pages.mjs');
const canvas = `<canvas id=c width=1280 height=720></canvas><script>const x=c.getContext('2d');let t=0;(function f(){t++;x.fillStyle='#fff';x.fillRect(0,0,1280,720);for(let i=0;i<200;i++){x.fillStyle='hsl('+(i*7+t)%360+' 70% 55%)';x.beginPath();x.arc(640+Math.cos(i+t/30)*i*2.5,360+Math.sin(i+t/40)*i*1.4,10,0,7);x.fill()}requestAnimationFrame(f)})()</script>`;
async function scenario(label, html, action) {
  if (html.startsWith('http')) await page.goto(html); else await page.setContent(html);
  await page.waitForTimeout(800);
  await page.evaluate(() => { window.__gaps = []; let last = 0; (function f(t) { if (last) window.__gaps.push(t - last); last = t; requestAnimationFrame(f); })(); });
  const a = sample(), t0 = performance.now(); const end = t0 + 8000;
  if (action === 'scroll') { await page.mouse.move(640, 360); let n = 0, dir = 1; while (performance.now() < end) { const t = performance.now(); await page.mouse.wheel(0, 60 * dir); if (++n % 80 === 0) dir = -dir; const w = 16 - (performance.now() - t); if (w > 0) await new Promise(r => setTimeout(r, w)); } }
  else await new Promise(r => setTimeout(r, 8000));
  const wall = (performance.now() - t0) / 1000, b = sample();
  const gaps = (await page.evaluate(() => window.__gaps)).sort((x, y) => x - y);
  const fps = gaps.length / (gaps.reduce((s, g) => s + g, 0) / 1000);
  const pct = k => +((b[k] - a[k]) / wall * 100).toFixed(1);
  console.log(JSON.stringify({ scenario: label, host: !!host, pageFps: +fps.toFixed(1), gapP50: +gaps[gaps.length >> 1]?.toFixed(1), gapP95: +gaps[Math.floor(gaps.length * .95)]?.toFixed(1), over20ms: gaps.filter(g => g > 20).length, cpuWebKit: pct('webkit'), cpuHost: pct('host'), cpuNode: pct('node'), cpuTotal: +(pct('webkit') + pct('host') + pct('node')).toFixed(1) }));
}
await scenario('static heavy page', heavy);
await scenario('user scrolling 60Hz (wheel)', heavy, 'scroll');
await scenario('real site scrolling', 'https://en.wikipedia.org/wiki/WebKit', 'scroll');
await scenario('canvas full repaint', canvas);
host?.kill(); await browser.close();
