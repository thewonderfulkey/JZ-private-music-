// 音质能力测试：同一首歌请求不同码率，观察返回的音质与URL
const BASE = 'http://localhost:3000';
const ID = 1357375695; // 海阔天空 - Beyond

async function main() {
  for (const br of [128000, 320000, 999000]) {
    const label = br === 999000 ? '无损FLAC(br=999000)' : `${br / 1000}kbps`;
    const ures = await fetch(`${BASE}/song/url?id=${ID}&br=${br}`);
    const ujson = await ures.json();
    const d = ujson.data && ujson.data[0];
    if (d && d.url) {
      console.log(`[${label}] code=${ujson.code} | 实际br=${d.br} | 大小=${d.size} | URL=${d.url.slice(0, 70)}...`);
    } else {
      console.log(`[${label}] code=${ujson.code} | 无URL: ${JSON.stringify(ujson.data || ujson).slice(0, 200)}`);
    }
  }
}
main().catch((e) => { console.error('失败:', e.message); process.exit(1); });
