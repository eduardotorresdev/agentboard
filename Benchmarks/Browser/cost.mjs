// Resource-cost spike: CPU time and RSS of the whole WebKit tree + this Node process (stands in
// for the sidecar), per scenario. Frames are forwarded through a pipe like the real sidecar would.
import { webkit, devices } from 'playwright-core';
import { execSync, spawn } from 'node:child_process';
import fs from 'node:fs';

const DUR = 8000;
const sink = spawn('cat', [], { stdio: ['pipe', 'ignore', 'inherit'] }); // stands in for the Swift side
const frameDir = 'frames'; fs.mkdirSync(frameDir, { recursive: true });

function cpuTime(t) { const p = t.split(':').map(Number); return p.reduce((a, v) => a * 60 + v, 0); }
function sample() {
  const out = execSync('ps -A -o pid=,time=,rss=,command=').toString().split('\n');
  let cpu = 0, rss = 0, procs = 0;
  for (const line of out) {
    const m = line.trim().match(/^(\d+)\s+(\S+)\s+(\d+)\s+(.*)$/); if (!m) continue;
    const [, pid, time, r, cmd] = m;
    if (Number(pid) === process.pid || cmd.includes('ms-playwright/webkit')) { cpu += cpuTime(time); rss += Number(r); procs++; }
  }
  return { cpu, rssMB: rss / 1024, procs };
}
async function measure(fn) {
  const a = sample(), t = performance.now();
  const extra = await fn();
  const wall = (performance.now() - t) / 1000, b = sample();
  return { cpuPct: +((b.cpu - a.cpu) / wall * 100).toFixed(1), rssMB: Math.round(b.rssMB), procs: b.procs, ...extra };
}

const heavy = `<style>body{font:15px -apple-system;margin:0;padding:24px;background:#fbfaff}
.card{margin:16px 0;padding:16px;border-radius:14px;background:#fff;box-shadow:0 4px 18px #2e1f6b22}
.box{display:inline-block;width:80px;height:80px;margin:4px;border-radius:12px}</style>` +
  Array.from({ length: 300 }, (_, i) => `<div class=card><h3>Section ${i}</h3><p>${'Lorem ipsum dolor sit amet, consectetur adipiscing elit. '.repeat(6)}</p>` +
  Array.from({ length: 6 }, (_, j) => `<span class=box style="background:hsl(${(i * 37 + j * 53) % 360} 70% 60%)"></span>`).join('') + `</div>`).join('');
const spinner = `<style>@keyframes s{to{transform:rotate(360deg)}}div{width:120px;height:120px;margin:80px;border-radius:24px;background:#6e56cf;animation:s 1s linear infinite}</style><div></div>`;
const canvas60 = `<canvas id=c width=1200 height=700></canvas><script>const x=c.getContext('2d');let t=0;(function f(){t++;x.fillStyle='#fff';x.fillRect(0,0,1200,700);for(let i=0;i<200;i++){x.fillStyle='hsl('+(i*7+t)%360+' 70% 55%)';x.beginPath();x.arc(600+Math.cos(i+t/30)*i*2.5,350+Math.sin(i+t/40)*i*1.4,10,0,7);x.fill()}requestAnimationFrame(f)})()</script>`;

const browser = await webkit.launch({ headless: true });
const results = [];
const idleBrowser = await measure(() => new Promise(r => setTimeout(r, 3000)));
results.push({ scenario: 'browser launched, no context', ...idleBrowser });

async function run(device, label, html, { screencast, size, quality = 70, fps, action }) {
  const ctx = await browser.newContext({ ...devices[device] });
  const page = await ctx.newPage();
  if (html.startsWith('http')) await page.goto(html, { waitUntil: 'load' }).catch(() => page.setContent(heavy)); else await page.setContent(html);
  await page.waitForTimeout(1500);
  let frames = 0, bytes = 0, lastFrameAt = 0, saved = 0;
  let sc;
  if (screencast) {
    sc = await page.screencast.start({ size, quality, fps, onFrame: f => {
      frames++; bytes += f.data.length; lastFrameAt = performance.now();
      const hdr = Buffer.alloc(4); hdr.writeUInt32LE(f.data.length); sink.stdin.write(hdr); sink.stdin.write(f.data);
      if (saved < 30) fs.writeFileSync(`${frameDir}/${device.replace(/\W/g, '')}-${size?.width ?? 'def'}-${saved++}.jpg`, f.data);
    } });
    await page.waitForTimeout(500); frames = 0; bytes = 0;
  }
  const lat = [];
  const r = await measure(async () => {
    const end = performance.now() + DUR;
    if (action === 'scroll') {
      const vp = page.viewportSize();
      await page.mouse.move(vp.width / 2, vp.height / 2);
      let dir = 1, n = 0;
      while (performance.now() < end) {
        const t = performance.now(), before = frames;
        if (devices[device].isMobile) await page.evaluate(([x, y, dy]) => { let e = document.elementFromPoint(x, y); while (e && e !== document.scrollingElement && !(e.scrollHeight > e.clientHeight && /auto|scroll/.test(getComputedStyle(e).overflowY))) e = e.parentElement; (e || document.scrollingElement).scrollBy(0, dy); }, [vp.width / 2, vp.height / 2, 60 * dir]); else await page.mouse.wheel(0, 60 * dir);
        if (++n % 80 === 0) dir = -dir;
        if (screencast && n % 10 === 0) { while (frames === before && performance.now() - t < 500) await new Promise(r => setTimeout(r, 1)); lat.push(performance.now() - t); }
        const wait = 16 - (performance.now() - t); if (wait > 0) await new Promise(r => setTimeout(r, wait));
      }
    } else await new Promise(r => setTimeout(r, DUR));
    lat.sort((a, b) => a - b);
    return { fps: +(frames / (DUR / 1000)).toFixed(1), kbPerFrame: frames ? +(bytes / frames / 1024).toFixed(1) : 0, MBps: +(bytes / DUR * 1000 / 1048576).toFixed(2),
      ...(lat.length ? { inputToFrameP50: Math.round(lat[lat.length >> 1]), inputToFrameP95: Math.round(lat[Math.floor(lat.length * 0.95)]) } : {}) };
  });
  console.log(JSON.stringify(results.at(-1) ?? {}));
  results.push({ scenario: `${device} · ${label} · ${screencast ? `screencast ${size ? size.width + 'x' + size.height : 'default'} q${quality}${fps ? ' fps' + fps : ''}` : 'no screencast'}`, ...r });
  if (sc) await sc.dispose?.();
  await ctx.close();
}

const desk = 'Desktop Safari', phone = 'iPhone 15';
const deskFull = { width: 1280, height: 720 }, deskCard = { width: 1024, height: 576 }, deskSmall = { width: 640, height: 360 };
await run(desk, 'static page', heavy, { screencast: false });
await run(desk, 'static page', heavy, { screencast: true, size: deskFull });
await run(desk, 'user scrolling 60Hz', heavy, { screencast: false, action: 'scroll' });
await run(desk, 'user scrolling 60Hz', heavy, { screencast: true, size: deskFull, action: 'scroll' });
await run(desk, 'user scrolling 60Hz', heavy, { screencast: true, size: deskFull, quality: 50, action: 'scroll' });
await run(desk, 'user scrolling 60Hz', heavy, { screencast: true, size: deskSmall, action: 'scroll' });
await run(desk, 'user scrolling 60Hz', heavy, { screencast: true, size: deskFull, fps: 30, action: 'scroll' });
await run(desk, 'real site, scrolling', 'https://en.wikipedia.org/wiki/WebKit', { screencast: true, size: deskFull, action: 'scroll' });
await run(desk, 'css spinner', spinner, { screencast: false });
await run(desk, 'css spinner', spinner, { screencast: true, size: deskFull });
await run(desk, 'canvas 60fps', canvas60, { screencast: false });
await run(desk, 'canvas 60fps', canvas60, { screencast: true, size: deskFull });
await run(desk, 'canvas 60fps', canvas60, { screencast: true, size: deskFull, fps: 15 });
await run(phone, 'user scrolling 60Hz', heavy, { screencast: true, size: { width: 393, height: 659 }, action: 'scroll' });
await run(phone, 'user scrolling 60Hz', heavy, { screencast: true, size: { width: 786, height: 1318 }, action: 'scroll' });

// Memory of N idle contexts (several browser blocks open at once).
for (const n of [1, 3, 6]) {
  const ctxs = [];
  for (let i = 0; i < n; i++) { const c = await browser.newContext({ ...devices[desk] }); const p = await c.newPage(); await p.setContent(heavy); ctxs.push(c); }
  await new Promise(r => setTimeout(r, 2000));
  const r = await measure(() => new Promise(r => setTimeout(r, 3000)));
  results.push({ scenario: `${n} idle contexts with heavy page`, ...r });
  for (const c of ctxs) await c.close();
}
await new Promise(r => setTimeout(r, 2000));
results.push({ scenario: 'after closing all contexts', ...(await measure(() => new Promise(r => setTimeout(r, 2000)))) });
await browser.close();
sink.stdin.end();
fs.writeFileSync('cost.json', JSON.stringify(results, null, 1));
for (const r of results) console.log(JSON.stringify(r));
