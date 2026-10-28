import { webkit, devices } from 'playwright-core';
const b = await webkit.launch();
for (const d of ['Desktop Safari', 'iPhone 15']) {
  const c = await b.newContext({ ...devices[d] }); const p = await c.newPage();
  await p.setContent(`<canvas id=c></canvas><script>const x=c.getContext('2d');let t=0;(function f(){x.fillStyle='hsl('+(t++)%360+' 60% 60%)';x.fillRect(0,0,300,150);requestAnimationFrame(f)})()</script>`);
  for (const size of [undefined, { width: 2560, height: 1440 }, { width: 786, height: 1318 }]) {
    let dims; const sc = await p.screencast.start({ size, onFrame: async f => { if (!dims) { const { default: sharp } = await Promise.resolve({ default: null }); dims = f.data; } } });
    await p.waitForTimeout(600); await sc.dispose();
    // read JPEG SOF0 dimensions
    const buf = dims; let i = 2, w, h; while (i < buf.length) { const m = buf[i + 1], len = buf.readUInt16BE(i + 2); if (m >= 0xC0 && m <= 0xC2) { h = buf.readUInt16BE(i + 5); w = buf.readUInt16BE(i + 7); break; } i += 2 + len; }
    console.log(d, 'viewport', JSON.stringify(p.viewportSize()), 'dpr', devices[d].deviceScaleFactor, 'requested', JSON.stringify(size), '-> jpeg', w + 'x' + h);
  }
  await c.close();
}
await b.close();
