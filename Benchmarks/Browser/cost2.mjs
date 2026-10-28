import { webkit, devices } from 'playwright-core';
import { execSync } from 'node:child_process';
function cpuTime(t) { return t.split(':').map(Number).reduce((a, v) => a * 60 + v, 0); }
function sample(filter) {
  let cpu = 0;
  for (const line of execSync('ps -A -o pid=,time=,command=').toString().split('\n')) {
    const m = line.trim().match(/^(\d+)\s+(\S+)\s+(.*)$/); if (!m) continue;
    if (filter(Number(m[1]), m[3])) cpu += cpuTime(m[2]);
  }
  return cpu;
}
const all = (pid, cmd) => pid === process.pid || cmd.includes('ms-playwright/webkit');
const nodeOnly = pid => pid === process.pid;
async function measure(ms) {
  const a = sample(all), n = sample(nodeOnly), t = performance.now();
  await new Promise(r => setTimeout(r, ms));
  const w = (performance.now() - t) / 1000;
  return { cpuPct: +((sample(all) - a) / w * 100).toFixed(1), nodePct: +((sample(nodeOnly) - n) / w * 100).toFixed(1) };
}
const browser = await webkit.launch({ headless: true });
const ctx = await browser.newContext({ ...devices['Desktop Safari'] });
const page = await ctx.newPage();
console.log('deviceScaleFactor', devices['Desktop Safari'].deviceScaleFactor);
await page.setContent('<h1>static</h1><p>nothing moves</p>');
await page.waitForTimeout(1000);
console.log('static, no screencast', await measure(6000));
for (const fps of [undefined, 5, 15, 30, 60]) {
  let frames = 0;
  const sc = await page.screencast.start({ size: { width: 1280, height: 720 }, quality: 70, fps, onFrame: () => frames++ });
  await page.waitForTimeout(500); frames = 0;
  const r = await measure(6000);
  console.log(`static, screencast fps=${fps}`, r, 'frames', frames);
  await sc.dispose();
  await page.waitForTimeout(500);
}
console.log('static, after screencast stopped', await measure(4000));
await page.setContent(`<canvas id=c width=1280 height=720></canvas><script>const x=c.getContext('2d');let t=0;(function f(){t++;x.fillStyle='hsl('+t%360+' 60% 60%)';x.fillRect(0,0,1280,720);requestAnimationFrame(f)})()</script>`);
await page.waitForTimeout(500);
let raf = await page.evaluate(() => new Promise(r => { let n = 0; const s = performance.now(); (function f() { n++; performance.now() - s < 2000 ? requestAnimationFrame(f) : r(n / 2); })(); }));
console.log('page rAF rate without screencast', raf);
for (const fps of [undefined, 30, 60]) for (const size of [{ width: 1280, height: 720 }, { width: 320, height: 180 }]) {
  let frames = 0;
  const sc = await page.screencast.start({ size, quality: 70, fps, onFrame: () => frames++ });
  await page.waitForTimeout(500); frames = 0;
  const r = await measure(5000);
  console.log(`canvas full-repaint, fps=${fps} size=${size.width}`, r, 'fps delivered', frames / 5);
  await sc.dispose();
}
await browser.close();
