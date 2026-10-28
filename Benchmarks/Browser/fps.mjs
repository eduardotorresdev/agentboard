import { webkit, devices } from 'playwright-core';
import { execSync } from 'node:child_process';
const cpuTime = t => t.split(':').map(Number).reduce((a, v) => a * 60 + v, 0);
const sample = () => execSync('ps -A -o pid=,time=,command=').toString().split('\n').reduce((s, l) => { const m = l.trim().match(/^(\d+)\s+(\S+)\s+(.*)$/); return m && (Number(m[1]) === process.pid || m[3].includes('ms-playwright/webkit')) ? s + cpuTime(m[2]) : s; }, 0);
const b = await webkit.launch();
for (const dev of ['Desktop Safari', 'iPhone 15']) {
  const c = await b.newContext({ ...devices[dev] }); const p = await c.newPage();
  await p.setContent(`<canvas id=c width=600 height=400></canvas><script>const x=c.getContext('2d');let t=0;(function f(){t++;x.fillStyle='hsl('+t%360+' 60% 60%)';x.fillRect(0,0,600,400);requestAnimationFrame(f)})()</script>`);
  const vp = p.viewportSize();
  for (const fps of [60, 120, 240]) for (const quality of [70, 40]) {
    let n = 0; const gaps = []; let last = 0;
    const sc = await p.screencast.start({ size: vp, quality, fps, onFrame: () => { const t = performance.now(); if (last) gaps.push(t - last); last = t; n++; } });
    await p.waitForTimeout(500); n = 0; gaps.length = 0;
    const a = sample(), t = performance.now(); await p.waitForTimeout(4000); const w = (performance.now() - t) / 1000;
    gaps.sort((x, y) => x - y);
    console.log(dev, `fps=${fps} q${quality}`, 'delivered', (n / w).toFixed(1), 'fps; gap p50', gaps[gaps.length >> 1]?.toFixed(1), 'p95', gaps[Math.floor(gaps.length * .95)]?.toFixed(1), 'ms; cpu', ((sample() - a) / w * 100).toFixed(0) + '%');
    await sc.dispose();
  }
  await c.close();
}
await b.close();
