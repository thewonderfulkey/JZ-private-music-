#!/usr/bin/env node
/**
 * 星澜聚合音源 StellarWave v4.0.2 —— LX 运行时仿真 + 黑盒连通性/稳定性实测
 *
 * 为什么用仿真器而不是「照着脚本重写一遍」：
 *   脚本里有 13/9/11/11/7/2 个后端池、Promise.any 并发前三 + 顺序兜底尾部、
 *   20 分钟 URL 缓存、3 次/秒滑动窗口限流、以及一堆 _u() 混淆和拼接 bug。
 *   重写必然走样；直接把它跑在 Node 里、只仿 LX 的 request/utils/crypto，
 *   测的就是真实代码路径（包括它自己的 bug）。
 *
 * 用法：
 *   node sw_harness.js --phase hosts       # 端点可达性（DNS/TLS/HTTP/延迟）
 *   node sw_harness.js --phase resolve     # 6 平台 × 2 档位 黑盒取流
 *   node sw_harness.js --phase stability --repeat 3   # 冷启动重复取流，看抖动
 *   node sw_harness.js --phase all
 */
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const crypto = require('node:crypto')
const http = require('node:http')
const https = require('node:https')
const { performance } = require('node:perf_hooks')

const SRC = process.env.SW_SRC || String.raw`C:\Users\17948\xwechat_files\wxid_bx89f9gkjtbc22_26bf\temp\RWTemp\2026-11\9e20f478899dc29eb19741386f9343c8\stellarwave音源（推荐）.js`

// ---------------------------------------------------------------- 全局节流
// 脚本自己限流 3 次/秒；这里再加「同 host 间隔 ≥1s」，避免把免费后端打挂
const PER_HOST_GAP = 1000
const SETTLE_MS = 5000   // 胜出后等落败分支落定，用于完整归因
const GLOBAL_QPS = 3
const hostLast = new Map()
const globalStamps = []
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function throttle(url) {
  let host = ''
  try { host = new URL(url).host } catch (_) { host = String(url).slice(0, 40) }
  for (;;) {
    const now = Date.now()
    while (globalStamps.length && now - globalStamps[0] >= 1000) globalStamps.shift()
    const last = hostLast.get(host) || 0
    const waitHost = PER_HOST_GAP - (now - last)
    const waitGlobal = globalStamps.length >= GLOBAL_QPS ? 1000 - (now - globalStamps[0]) + 10 : 0
    const w = Math.max(waitHost, waitGlobal, 0)
    if (w <= 0) { hostLast.set(host, now); globalStamps.push(now); return }
    await sleep(Math.min(w, 1200))
  }
}

// ---------------------------------------------------------------- 线材日志
/** 每次真实 HTTP 往返都记一条，用来反推「哪个后端通了」 */
let wire = []
function logWire(rec) { wire.push(rec) }

// ---------------------------------------------------------------- LX request 仿真
const MAX_REDIRECT = 5

function rawRequest(urlStr, options = {}, redirects = 0) {
  return new Promise((resolve, reject) => {
    let u
    try { u = new URL(urlStr) } catch (e) { return reject(new Error('非法URL: ' + urlStr)) }
    const isHttps = u.protocol === 'https:'
    const mod = isHttps ? https : http
    const headers = { ...(options.headers || {}) }
    if (!headers['Accept-Encoding']) headers['Accept-Encoding'] = 'identity'
    const started = performance.now()
    const body = options.body
    if (body != null) headers['Content-Length'] = Buffer.byteLength(String(body))
    const req = mod.request({
      protocol: u.protocol,
      hostname: u.hostname,
      port: u.port || (isHttps ? 443 : 80),
      path: u.pathname + u.search,
      method: options.method || 'GET',
      headers,
      servername: u.hostname,
      rejectUnauthorized: !/^(103\.79|106\.55|175\.27\.)/.test(u.hostname), // 裸 IP 后端多是自签
      timeout: options.timeout || 15000,
    }, (res) => {
      const chunks = []
      let size = 0
      res.on('data', (c) => { chunks.push(c); size += c.length; if (size > 2_000_000) req.destroy() })
      res.on('end', () => {
        const ms = Math.round(performance.now() - started)
        const buf = Buffer.concat(chunks)
        const rec = {
          url: urlStr, status: res.statusCode, ms, bytes: buf.length,
          ct: res.headers['content-type'] || '',
          loc: res.headers['location'] || '',
        }
        logWire(rec)
        // 跟重定向（脚本里 follow_max 是 LX 的扩展字段，这里统一实现）
        if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location && redirects < MAX_REDIRECT) {
          const next = new URL(res.headers.location, u).toString()
          resolve(rawRequest(next, { ...options, method: res.statusCode === 303 ? 'GET' : options.method }, redirects + 1))
          return
        }
        resolve({
          statusCode: res.statusCode,
          headers: res.headers,
          body: buf,          // 交给 lx.utils.buffer 解
          __buf: buf,
        })
      })
      res.on('error', reject)
    })
    req.on('timeout', () => { req.destroy(new Error('请求超时 ' + (options.timeout || 15000) + 'ms')) })
    req.on('error', (e) => {
      const ms = Math.round(performance.now() - started)
      logWire({ url: urlStr, status: 0, ms, bytes: 0, ct: '', err: e.code || e.message })
      reject(e)
    })
    if (body != null) req.write(String(body))
    req.end()
  })
}

// ---------------------------------------------------------------- LX utils 仿真
const md5 = (s) => crypto.createHash('md5').update(s, 'utf8').digest('hex')

const utils = {
  crypto: {
    md5,
    /** 对齐 LX：aesEncrypt(data, mode, key, iv) */
    aesEncrypt(data, mode, key, iv) {
      const CIPHERS = {
        'aes-128-cbc': 'aes-128-cbc', 'aes-128-ecb': 'aes-128-ecb',
        'aes-192-cbc': 'aes-192-cbc', 'aes-192-ecb': 'aes-192-ecb',
        'aes-256-cbc': 'aes-256-cbc', 'aes-256-ecb': 'aes-256-ecb',
      }
      const algo = CIPHERS[mode]
      if (!algo) throw new Error('不支持的模式 ' + mode)
      const k = Buffer.from(key, 'utf8')
      const need = { 128: 16, 192: 24, 256: 32 }[Number(algo.split('-')[1])]
      // LX 内部会按 mode 位数补齐/裁剪 key
      const keyBuf = k.length === need ? k : Buffer.concat([k, Buffer.alloc(need)]).subarray(0, need)
      const ivBuf = algo.includes('ecb') ? null : Buffer.from(iv || '', 'utf8')
      const ivOk = ivBuf && ivBuf.length === 16 ? ivBuf : (algo.includes('ecb') ? null : Buffer.alloc(16))
      const c = crypto.createCipheriv(algo, keyBuf, ivOk)
      c.setAutoPadding(true)
      return Buffer.concat([c.update(Buffer.from(data, 'utf8')), c.final()])
    },
  },
  buffer: {
    bufToString(buf, fmt) {
      const b = Buffer.isBuffer(buf) ? buf : Buffer.from(buf)
      return fmt === 'hex' ? b.toString('hex') : b.toString('utf8')
    },
  },
}

// ---------------------------------------------------------------- 载入脚本
function loadSource() {
  const raw = fs.readFileSync(SRC, 'utf8')
  wire = []
  let inited = null
  let handler = null
  const logs = []

  const lx = {
    EVENT_NAMES: { request: 'request', inited: 'inited', updateAlert: 'updateAlert' },
    request: (url, options, cb) => {
      throttle(url).then(() => rawRequest(url, options))
        .then((resp) => cb(null, resp))
        .catch((err) => cb(err))
    },
    on: (name, fn) => { if (name === 'request') handler = fn },
    send: (name, data) => { if (name === 'inited') inited = data },
    utils,
    env: 'desktop',
    version: '2.11.0',
    currentScriptInfo: { name: 'stellarwave', rawScript: raw },
  }

  const sandbox = {
    lx,
    console: { log: (...a) => logs.push(a.join(' ')), warn: (...a) => logs.push(a.join(' ')), error: (...a) => logs.push(a.join(' ')) },
    setTimeout, clearTimeout, setInterval, clearInterval,
    Buffer, URL, TextEncoder, TextDecoder,
  }
  const ctx = vm.createContext(sandbox)
  vm.runInContext(raw, ctx, { filename: 'stellarwave.js', timeout: 15000 })

  if (!handler) throw new Error('脚本没有注册 request 事件')
  return { handler, inited, logs, raw }
}

// ---------------------------------------------------------------- 测试锚点
// 版权状态取自本仓库《GitHub音乐源连通性测试报告》4.1 锚点表（实测过）
const ANCHORS = {
  tx: { label: '晴天/周杰伦(QQ VIP)', musicInfo: { songmid: '0039MnYb0qxYhV', name: '晴天', singer: '周杰伦', interval: '04:29', albumName: '叶惠美' } },
  wy: { label: '演员/薛之谦(网易 VIP)', musicInfo: { songmid: '32507038', songId: '32507038', name: '演员', singer: '薛之谦' } },
  kw: { label: '晴天/周杰伦(酷我免费)', musicInfo: { songmid: '228908', rid: '228908', name: '晴天', singer: '周杰伦' } },
  kg: { label: '晴天/周杰伦(酷狗 VIP)', musicInfo: { hash: '1B56126A8A03924F1DD066259C095CBC', songmid: '1B56126A8A03924F1DD066259C095CBC', albumId: '966846', name: '晴天', singer: '周杰伦' } },
  mg: { label: '晴天/周杰伦(咪咕)', musicInfo: { songmid: '60054701923', copyrightId: '60054701923', musicId: '3790007', id: '3790007', name: '晴天', singer: '周杰伦' } },
  qs: { label: '汽水(无公开曲库ID)', musicInfo: { songmid: '0000000000', name: '晴天', singer: '周杰伦' } },
}

// 第二组锚点：换一首歌（大鱼/周深，全平台 VIP，pay_type=3），用来验证
// 「第一组通过」不是只对这一首歌成立的偶然
const ANCHORS_2 = {
  tx: { label: '大鱼/周深(QQ VIP)', musicInfo: { songmid: '004OQ5Mt0EmEzv', name: '大鱼', singer: '周深', interval: '05:13', albumName: '大鱼' } },
  wy: { label: '大鱼/周深(网易 VIP)', musicInfo: { songmid: '516823132', songId: '516823132', name: '大鱼', singer: '周深' } },
  kw: { label: '大鱼/周深(酷我 VIP)', musicInfo: { songmid: '7095195', rid: '7095195', name: '大鱼', singer: '周深' } },
  kg: { label: '大鱼/周深(酷狗 VIP)', musicInfo: { hash: 'BCEC0087B8CCF17A15298DC5B64F5323', songmid: 'BCEC0087B8CCF17A15298DC5B64F5323', albumId: '1637713', name: '大鱼', singer: '周深' } },
  mg: { label: '大鱼/周深(咪咕)', musicInfo: { songmid: '64380800312', copyrightId: '64380800312', musicId: '1003495338', id: '1003495338', name: '大鱼', singer: '周深' } },
  qs: { label: '汽水(无公开曲库ID)', musicInfo: { songmid: '0000000000', name: '大鱼', singer: '周深' } },
}
let ANCH = ANCHORS
const setAnchorSet = (n) => { ANCH = n === 2 ? ANCHORS_2 : ANCHORS }

const QUALITIES = {
  tx: ['320k', 'flac'], wy: ['320k', 'flac'], kw: ['320k', 'flac'],
  kg: ['320k', 'flac'], mg: ['320k', 'flac'], qs: ['320k'],
}
const PLATFORM_CN = { tx: 'QQ音乐', wy: '网易云', kw: '酷我', kg: '酷狗', mg: '咪咕', qs: '汽水' }

// ---------------------------------------------------------------- 一条取流
async function resolveOnce(handler, source, quality) {
  const t0 = performance.now()
  try {
    const url = await handler({ action: 'musicUrl', source, info: { musicInfo: ANCH[source].musicInfo, type: quality } })
    return { ok: true, url, ms: Math.round(performance.now() - t0) }
  } catch (e) {
    return { ok: false, err: String(e && e.message ? e.message : e), ms: Math.round(performance.now() - t0) }
  }
}

// ---------------------------------------------------------------- 音频真实性校验
function sniff(buf) {
  if (!buf || buf.length < 4) return 'unknown'
  const s = buf.subarray(0, 16)
  if (s.subarray(0, 3).toString('latin1') === 'ID3') return 'mp3'
  if (s[0] === 0xff && (s[1] & 0xe0) === 0xe0) return 'mp3'
  if (s.subarray(0, 4).toString('latin1') === 'fLaC') return 'flac'
  if (s.subarray(0, 4).toString('latin1') === 'OggS') return 'ogg'
  if (s.subarray(4, 8).toString('latin1') === 'ftyp') return 'm4a'
  if (s.subarray(0, 4).toString('latin1') === 'RIFF') return 'wav'
  return 'unknown'
}

const AUDIO_MAX_REDIRECT = 4

/**
 * 探测一条直链。**必须跟 302**：星海系（yy.zddyr.top/lx/api/kwplay.php）与 HYW 咪咕
 * 给的都不是 CDN 直链，而是自己的跳板；不跟就只能看到 302 而误判"不可播"。
 * 跟完之后把跳转链记下来——因为「播放时刻每次 seek 都要回到跳板」是真实的稳定性风险。
 */
async function inspectAudio(urlStr, chain = []) {
  let u
  try { u = new URL(urlStr) } catch (_) { return { ok: false, err: '非法URL' } }
  if (chain.length > AUDIO_MAX_REDIRECT) return { ok: false, err: '重定向过多', chain }
  const isHttps = u.protocol === 'https:'
  const mod = isHttps ? https : http
  const referer = /126\.net|163\.com/.test(u.host) ? 'https://music.163.com/'
    : /kuwo/.test(u.host) ? 'https://www.kuwo.cn/'
      : /kugou/.test(u.host) ? 'https://m.kugou.com/'
        : /qq\.com|gtimg/.test(u.host) ? 'https://y.qq.com/' : 'https://music.qq.com/'
  return new Promise((resolve) => {
    const started = performance.now()
    const req = mod.request({
      protocol: u.protocol, hostname: u.hostname, port: u.port || (isHttps ? 443 : 80),
      path: u.pathname + u.search, method: 'GET',
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        Accept: '*/*', Range: 'bytes=0-8191', Referer: referer,
        'Accept-Encoding': 'identity',
      },
      timeout: 12000, rejectUnauthorized: !/^(103\.79|106\.55|175\.27\.)/.test(u.hostname),
    }, (res) => {
      // 302 → 跟到真正的 CDN，记下跳转链
      if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
        const next = new URL(res.headers.location, u).toString()
        res.resume()
        res.on('end', () => {
          inspectAudio(next, [...chain, `${u.host}→${new URL(next).host}`])
            .then((r) => resolve({ ...r, hops: chain.length + 1 }))
        })
        return
      }
      let got = Buffer.alloc(0)
      res.on('data', (c) => { got = Buffer.concat([got, c]); if (got.length >= 8192) req.destroy() })
      const finish = () => {
        const cr = res.headers['content-range'] || ''
        let total = 0
        const m = /\/(\d+)$/.exec(cr)
        if (m) total = Number(m[1])
        else if (res.headers['content-length']) total = Number(res.headers['content-length'])
        resolve({
          ok: res.statusCode >= 200 && res.statusCode < 400,
          status: res.statusCode, ms: Math.round(performance.now() - started),
          container: sniff(got), totalBytes: total, rangeOK: res.statusCode === 206,
          ct: res.headers['content-type'] || '', gotBytes: got.length,
          host: u.host, chain,
        })
      }
      res.on('end', finish)
      res.on('close', finish)
      res.on('error', () => resolve({ ok: false, err: 'stream error', host: u.host }))
    })
    req.on('timeout', () => { req.destroy(); resolve({ ok: false, err: 'timeout', host: u.host }) })
    req.on('error', (e) => resolve({ ok: false, err: e.code || e.message, host: u.host }))
    req.end()
  })
}

// ---------------------------------------------------------------- 端点清单（解混淆）
function decodeU(s) { return s.split('').map((c) => String.fromCharCode(c.charCodeAt(0) + 5)).join('') }

function hostInventory(raw) {
  const unesc = (b) => b.replace(/\\(.)/g, (_, c) => ({ n: '\n', t: '\t', r: '\r' }[c] ?? c))
  const hosts = new Map()
  const add = (u, line) => {
    let h
    try { h = new URL(u).host } catch (_) { return }
    if (!hosts.has(h)) hosts.set(h, { host: h, lines: new Set(), samples: [] })
    const e = hosts.get(h)
    e.lines.add(line)
    if (e.samples.length < 2) e.samples.push(u.slice(0, 130))
  }
  const lineOf = (idx) => raw.slice(0, idx).split('\n').length
  for (const m of raw.matchAll(/_u\(\s*(['"])((?:\\.|(?!\1).)*)\1\s*\)/g)) {
    add(decodeU(unesc(m[2])), lineOf(m.index))
  }
  for (const m of raw.matchAll(/https?:\/\/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]{4,}/g)) {
    add(m[0].replace(/['",)]+$/, ''), lineOf(m.index))
  }
  return [...hosts.values()]
    .filter((e) => !['github.com', 'your-repo'].includes(e.host))
    .map((e) => ({ host: e.host, lines: [...e.lines].sort((a, b) => a - b), samples: e.samples }))
    .sort((a, b) => a.host.localeCompare(b.host))
}

// ---------------------------------------------------------------- 阶段：端点可达性
async function phaseHosts(raw) {
  const inv = hostInventory(raw)
  console.log(`\n### 阶段 1 · 端点可达性（${inv.length} 个独立 host）\n`)
  const rows = []
  for (const e of inv) {
    const url = `https://${e.host}/`
    let rec
    try {
      const r = await rawRequest(url, { method: 'HEAD', timeout: 10000 })
      rec = { status: r.statusCode, ms: wire[wire.length - 1].ms }
    } catch (err) {
      const w = wire[wire.length - 1] || {}
      try {
        const r2 = await rawRequest(url, { method: 'GET', timeout: 10000 })
        rec = { status: r2.statusCode, ms: wire[wire.length - 1].ms }
      } catch (e2) {
        rec = { status: 0, ms: w.ms || 0, err: e2.code || e2.message }
      }
    }
    rows.push({ ...e, ...rec })
    const flag = rec.status >= 200 && rec.status < 500 ? 'OK ' : 'ERR'
    console.log(`${flag} ${String(rec.status || '—').padEnd(4)} ${String(rec.ms ?? '—').padStart(6)}ms  ${e.host.padEnd(30)} ${rec.err || ''}`)
  }
  return rows
}

// ---------------------------------------------------------------- 阶段：黑盒取流
async function phaseResolve() {
  console.log('\n### 阶段 2 · 6 平台 × 档位 黑盒取流（真实跑脚本代码）\n')
  const results = []
  for (const source of Object.keys(ANCH)) {
    for (const quality of QUALITIES[source]) {
      const { handler } = loadSource()
      const r = await resolveOnce(handler, source, quality)
      // Promise.any 不会取消落败分支；等它们落定再快照，才能看清「谁回、谁没回」。
      // 否则只会看到胜出那一刻之前完成的请求，误以为某些后端"没被调用"。
      await sleep(SETTLE_MS)
      const entry = {
        platform: source, platformCN: PLATFORM_CN[source], anchor: ANCH[source].label,
        quality, ok: r.ok, ms: r.ms, url: r.url || '', err: r.err || '',
        wire: wire.map((w) => ({ status: w.status, ms: w.ms, host: safeHost(w.url), err: w.err || '', bytes: w.bytes })),
      }
      if (r.ok) {
        entry.audio = await inspectAudio(r.url)
      }
      results.push(entry)
      const a = entry.audio
      console.log(
        `${r.ok ? '✅' : '❌'} ${PLATFORM_CN[source]} ${quality.padEnd(6)} ${String(r.ms).padStart(6)}ms ` +
        (r.ok
          ? `→ ${a ? `${a.container}/${a.status}/${a.totalBytes ? (a.totalBytes / 1048576).toFixed(1) + 'MB' : '—'}` : '未探测'} @${safeHost(r.url)}`
          : `→ ${r.err.split('\n')[0].slice(0, 70)}`)
      )
    }
  }
  return results
}

function safeHost(u) { try { return new URL(u).host } catch (_) { return String(u).slice(0, 40) } }

// ---------------------------------------------------------------- 阶段：稳定性
async function phaseStability(repeat) {
  console.log(`\n### 阶段 3 · 稳定性（每档位冷启动 ${repeat} 次）\n`)
  const out = []
  for (const source of Object.keys(ANCH)) {
    for (const quality of QUALITIES[source]) {
      const runs = []
      for (let i = 0; i < repeat; i++) {
        const { handler } = loadSource()          // 每次全新上下文 = 无 URL 缓存
        const r = await resolveOnce(handler, source, quality)
        runs.push({ ok: r.ok, ms: r.ms, url: r.url || '', err: (r.err || '').split('\n')[0] })
        await sleep(1500)
      }
      const okCount = runs.filter((r) => r.ok).length
      const lat = runs.map((r) => r.ms)
      out.push({ platform: source, quality, okCount, repeat, lat, runs })
      console.log(
        `${okCount === repeat ? '✅' : okCount === 0 ? '❌' : '⚠️ '} ${PLATFORM_CN[source]} ${quality.padEnd(6)} ` +
        `${okCount}/${repeat} 命中 · 延迟 ${lat.join('/')}ms`
      )
    }
  }
  return out
}

// ---------------------------------------------------------------- main
async function main() {
  const argv = process.argv.slice(2)
  const arg = (k, d) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : d }
  const phase = arg('--phase', 'all')
  const repeat = Number(arg('--repeat', 3))
  setAnchorSet(Number(arg('--songs', 1)))
  const outDir = path.join(__dirname, 'out')
  fs.mkdirSync(outDir, { recursive: true })

  console.log('='.repeat(78))
  console.log('星澜聚合音源 StellarWave v4.0.2 · LX 运行时仿真实测')
  console.log('源文件：' + SRC)
  console.log('='.repeat(78))

  // 载入一次，打印脚本自报信息（相当于 LX 里"音源已加载"）
  const boot = loadSource()
  console.log('\n--- 脚本自报（send(inited)）---')
  const sources = boot.inited && boot.inited.sources
  if (sources) {
    for (const [k, v] of Object.entries(sources)) {
      console.log(`  ${k.padEnd(3)} ${v.name.padEnd(10)} actions=${v.actions.join(',')} qualitys=${v.qualitys.join('/')}`)
    }
  } else {
    console.log('  ⚠️ 未收到 inited 事件')
  }
  console.log('--- 加载期 console ---')
  boot.logs.slice(0, 8).forEach((l) => console.log('  ' + l))

  const report = { source: SRC, at: new Date().toISOString() }

  if (['hosts', 'all'].includes(phase)) report.hosts = await phaseHosts(fs.readFileSync(SRC, 'utf8'))
  if (['resolve', 'all'].includes(phase)) report.resolve = await phaseResolve()
  if (['stability', 'all'].includes(phase)) report.stability = await phaseStability(repeat)

  const outFile = path.join(outDir, `report-${phase}-${Date.now()}.json`)
  fs.writeFileSync(outFile, JSON.stringify(report, null, 2))
  console.log('\n原始结果 → ' + outFile)
}

main().catch((e) => { console.error('致命错误：', e); process.exit(1) })


