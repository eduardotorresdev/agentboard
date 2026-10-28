import { webkit, devices } from 'playwright-core';
const b = await webkit.launch(); const c = await b.newContext({ ...devices['Desktop Safari'] }); const p = await c.newPage();
await p.goto('https://en.wikipedia.org/wiki/WebKit').catch(() => {});
for (const [label, o] of [['jpeg css-scale q70', { type: 'jpeg', quality: 70, scale: 'css' }], ['jpeg device-scale q70', { type: 'jpeg', quality: 70 }], ['png device-scale', { type: 'png' }]]) {
  const t = []; let bytes = 0;
  for (let i = 0; i < 10; i++) { const s = performance.now(); const buf = await p.screenshot(o); t.push(performance.now() - s); bytes = buf.length; }
  t.sort((a, b) => a - b); console.log(label, 'p50', Math.round(t[5]), 'ms', Math.round(bytes / 1024), 'KB');
}
await b.close();
