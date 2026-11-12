// 连通性测试脚本：搜索 → 获取歌曲URL → 下载 → 校验文件头
// 用法: node test-api.js [关键词]
const fs = require('fs');
const path = require('path');

const BASE = process.env.API_BASE || 'http://localhost:3000';
const KEYWORD = process.argv[2] || '海阔天空 Beyond';
const OUT_DIR = path.join(__dirname, 'downloads');

async function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });

  // 1. 搜索
  console.log(`[1] 搜索关键词: ${KEYWORD}`);
  const sres = await fetch(`${BASE}/search?keywords=${encodeURIComponent(KEYWORD)}&limit=3`);
  const sjson = await sres.json();
  console.log('    响应 code:', sjson.code);
  const songs = (sjson.result && sjson.result.songs) || [];
  if (!songs.length) { console.log('    未找到歌曲，结束'); return; }
  const song = songs[0];
  const artists = (song.artists || []).map((a) => a.name).join('/');
  console.log(`    命中: [id=${song.id}] ${song.name} - ${artists}`);

  // 2. 获取歌曲 URL
  console.log(`[2] 调用 /song/url?id=${song.id}`);
  const ures = await fetch(`${BASE}/song/url?id=${song.id}`);
  const ujson = await ures.json();
  console.log('    /song/url code:', ujson.code);
  const data = ujson.data && ujson.data[0];
  if (!data || !data.url) {
    console.log('    无可用 URL，原始响应:');
    console.log('    ' + JSON.stringify(ujson.data || ujson).slice(0, 500));
    return;
  }
  console.log(`    音质 br=${data.br} | 文件大小=${data.size} 字节 | 时长=${data.time} 秒`);
  console.log(`    URL 前缀: ${data.url.substring(0, 100)}`);

  // 3. 下载
  console.log('[3] 开始下载...');
  const dres = await fetch(data.url);
  const buf = Buffer.from(await dres.arrayBuffer());
  const ext = detectExt(buf);
  const fname = path.join(OUT_DIR, `${song.id}_${sanitize(song.name)}.${ext}`);
  fs.writeFileSync(fname, buf);
  console.log(`    已保存: ${fname} (${buf.length} 字节)`);

  // 4. 校验文件头
  console.log('[4] 文件校验');
  console.log(`    HEX 头: ${buf.slice(0, 16).toString('hex').toUpperCase()}`);
  console.log(`    ASCII:  ${buf.slice(0, 16).toString('ascii').replace(/[^\x20-\x7E]/g, '.')}`);
  const looksLikeHtml = buf.length > 0 && /<!DOCTYPE|<html/i.test(buf.toString('utf8', 0, Math.min(1000, buf.length)));
  const verdict = !looksLikeHtml && ext !== 'bin' ? '✅ 真实音频文件（魔数匹配）' : (looksLikeHtml ? '❌ 疑似返回 HTML 错误页' : '⚠️ 未知格式，需人工检查');
  console.log(`    判定: ${verdict} | 格式: ${ext}`);
}

function detectExt(buf) {
  if (buf.length > 4 && buf.toString('ascii', 0, 4) === 'fLaC') return 'flac';
  if (buf.length > 12 && buf.toString('ascii', 0, 4) === 'RIFF' && buf.toString('ascii', 8, 12) === 'WAVE') return 'wav';
  if (buf.length > 8 && buf.toString('ascii', 4, 8) === 'ftyp') return 'm4a';
  if (buf.length > 3 && buf.toString('ascii', 0, 3) === 'ID3') return 'mp3';
  if (buf.length > 2 && buf[0] === 0xff && (buf[1] & 0xe0) === 0xe0) return 'mp3';
  return 'bin';
}

function sanitize(s) { return String(s).replace(/[\\/:*?"<>|]/g, '_'); }

main().catch((e) => { console.error('脚本失败:', e.message); process.exit(1); });
