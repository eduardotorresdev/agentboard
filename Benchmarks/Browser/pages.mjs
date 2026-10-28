// Test pages shared by the browser benchmarks.
export const heavy = `<style>body{font:15px -apple-system;margin:0;padding:24px;background:#fbfaff}
.card{margin:16px 0;padding:16px;border-radius:14px;background:#fff;box-shadow:0 4px 18px #2e1f6b22}
.box{display:inline-block;width:80px;height:80px;margin:4px;border-radius:12px}</style>` +
  Array.from({ length: 300 }, (_, i) => `<div class=card><h3>Section ${i}</h3><p>${'Lorem ipsum dolor sit amet, consectetur adipiscing elit. '.repeat(6)}</p>` +
  Array.from({ length: 6 }, (_, j) => `<span class=box style="background:hsl(${(i * 37 + j * 53) % 360} 70% 60%)"></span>`).join('') + `</div>`).join('');
