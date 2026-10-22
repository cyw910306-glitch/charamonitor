// 내 설정 파일 (.charamonitor) reader for the web app: a strict, bounded binary plist parser and the same container and
// pack rules as the Mac app (Sources/DogMonitor/App/SetupFile.swift, Sprite/CharacterPack.swift). Pure: no DOM, so
// tools/web-app/check-setup.mjs runs it in Node. Nothing here sends anything anywhere.
(function (root) {
  'use strict'
  const LIMITS = { bytes: 64 * 1024 * 1024, entries: 5000, fileBytes: 50 * 1024 * 1024, depth: 8, objects: 200000, nest: 32 }
  const FOLDERS = ['Packs', 'Characters', 'Pictures']
  const POSES = ['lying', 'slowWalk', 'walk', 'fastWalk', 'run', 'sprint', 'exhausted']
  const EXTRAS = ['hungry', 'eat', 'special']
  const PERSONAS = ['friendly', 'calm', 'shy', 'proud', 'bright', 'polite', 'cry']
  const PACK = { pngBytes: 64 * 1024, jsonBytes: 16 * 1024, maxPacks: 32, maxTakes: 4, maxLines: 6, lineLength: 60 }

  class SetupError extends Error {
    constructor(code) { super(code); this.code = code }   // bad | newer | notAllowed | tooBig
  }
  const fail = code => { throw new SetupError(code) }

  // MARK: binary plist (bplist00)

  function parseBplist(u8) {
    if (!(u8 instanceof Uint8Array) || u8.length < 40) fail('bad')
    if (String.fromCharCode(...u8.subarray(0, 8)) !== 'bplist00') fail('bad')
    const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength)
    const trailer = u8.length - 32
    const uint = (p, n) => {
      if (p < 0 || p + n > u8.length) fail('bad')
      let v = 0
      for (let i = 0; i < n; i++) v = v * 256 + u8[p + i]
      if (v > Number.MAX_SAFE_INTEGER) fail('bad')
      return v
    }
    const offSize = u8[trailer + 6], refSize = u8[trailer + 7]
    const count = uint(trailer + 8, 8), top = uint(trailer + 16, 8), table = uint(trailer + 24, 8)
    if (offSize < 1 || offSize > 8 || refSize < 1 || refSize > 8 || count < 1 || top >= count) fail('bad')
    if (table < 8 || table + count * offSize > trailer) fail('bad')
    const need = (p, n) => { if (p < 8 || n < 0 || p + n > table) fail('bad') }
    const offset = i => { const o = uint(table + i * offSize, offSize); need(o, 1); return o }
    const open = new Set(), leaves = new Map()
    let made = 0, spent = 0
    // A leaf (string, data) is decoded once per ref, and all leaves together can not outgrow the file: refs that point
    // at the same bytes many times can not blow up memory.
    const leaf = (ref, n, make) => {
      if ((spent += n) > u8.length) fail('bad')
      const v = make()
      leaves.set(ref, v)
      return v
    }
    const many = n => { if (n > LIMITS.objects) fail('bad'); return n }

    function length(p, lo) {
      if (lo < 15) return [lo, p + 1]
      need(p + 1, 1)
      const m = u8[p + 1]
      if (m >> 4 !== 1 || (m & 15) > 3) fail('bad')
      const n = 1 << (m & 15)
      need(p + 2, n)
      return [uint(p + 2, n), p + 2 + n]
    }
    function refs(start, n) {
      need(start, n * refSize)
      const out = new Array(n)
      for (let i = 0; i < n; i++) out[i] = uint(start + i * refSize, refSize)
      return out
    }
    function obj(ref, depth) {
      if (ref >= count || depth > LIMITS.nest || open.has(ref) || ++made > LIMITS.objects) fail('bad')
      if (leaves.has(ref)) return leaves.get(ref)
      const p = offset(ref), m = u8[p], hi = m >> 4, lo = m & 15
      switch (hi) {
        case 0x0:
          if (m === 0x08) return false
          if (m === 0x09) return true
          return fail('bad')
        case 0x1: {
          if (lo > 3) fail('bad')
          const n = 1 << lo
          need(p + 1, n)
          if (n < 8) return uint(p + 1, n)
          const v = dv.getBigInt64(p + 1)
          if (v > BigInt(Number.MAX_SAFE_INTEGER) || v < BigInt(Number.MIN_SAFE_INTEGER)) fail('bad')
          return Number(v)
        }
        case 0x2:
          if (lo === 2) { need(p + 1, 4); return dv.getFloat32(p + 1) }
          if (lo === 3) { need(p + 1, 8); return dv.getFloat64(p + 1) }
          return fail('bad')
        case 0x3:
          if (m !== 0x33) fail('bad')
          need(p + 1, 8)
          return new Date((978307200 + dv.getFloat64(p + 1)) * 1000)
        case 0x4: {
          const [n, s] = length(p, lo)
          need(s, n)
          return leaf(ref, n, () => u8.subarray(s, s + n))
        }
        case 0x5: {
          const [n, s] = length(p, lo)
          need(s, n)
          return leaf(ref, n, () => {
            let out = ''
            for (let i = 0; i < n; i++) { if (u8[s + i] > 127) fail('bad'); out += String.fromCharCode(u8[s + i]) }
            return out
          })
        }
        case 0x6: {
          const [n, s] = length(p, lo)
          need(s, n * 2)
          return leaf(ref, n * 2, () => new TextDecoder('utf-16be', { fatal: true }).decode(u8.subarray(s, s + n * 2)))
        }
        case 0xA: {
          const [n, s] = length(p, lo)
          const r = refs(s, many(n))
          open.add(ref)
          const out = r.map(x => obj(x, depth + 1))
          open.delete(ref)
          return out
        }
        case 0xD: {
          const [n, s] = length(p, lo)
          const keys = refs(s, many(n)), vals = refs(s + n * refSize, n)
          open.add(ref)
          const out = new Map()
          for (let i = 0; i < n; i++) {
            const k = obj(keys[i], depth + 1)
            if (typeof k !== 'string' || out.has(k)) fail('bad')
            out.set(k, obj(vals[i], depth + 1))
          }
          open.delete(ref)
          return out
        }
        default:
          return fail('bad')   // uid, sets and the rest: never in a setup file
      }
    }
    return obj(top, 0)
  }

  // MARK: the container (SetupFile.stage)

  const utf8Length = s => new TextEncoder().encode(s).length
  // A relative path, split: one of FOLDERS on top, then plain NFC names, at most LIMITS.depth deep; null when any fails.
  function components(path) {
    const parts = path.split('/')
    if (parts.length < 2 || parts.length > LIMITS.depth || !FOLDERS.includes(parts[0])) return null
    for (const p of parts) {
      if (!p || p === '.' || p === '..' || p.startsWith('._') || utf8Length(p) > 255 || p !== p.normalize('NFC')) return null
      if (/[\\\u0000-\u001f\u007f-\u009f]/.test(p)) return null
    }
    return parts
  }
  const fold = parts => parts.join('/').toLowerCase().normalize('NFC')

  function readSetup(u8) {
    if (!(u8 instanceof Uint8Array) || u8.length === 0) fail('bad')
    if (u8.length > LIMITS.bytes) fail('tooBig')
    const root = parseBplist(u8)
    if (!(root instanceof Map) || typeof root.get('format') !== 'number' || !Number.isInteger(root.get('format'))) fail('bad')
    if (root.get('format') > 2) fail('newer')
    const keys = [...root.keys()].sort().join()
    if (root.get('format') !== 2 || keys !== 'app,created,files,format,settings') fail('bad')
    const settings = root.get('settings'), files = root.get('files')
    if (typeof root.get('app') !== 'string' || !(root.get('created') instanceof Date) || !(settings instanceof Map) || !(files instanceof Map)) fail('bad')
    if (files.size > LIMITS.entries) fail('notAllowed')
    const taken = new Set(), dirs = new Set()
    let total = 0
    for (const [path, bytes] of files) {
      if (!(bytes instanceof Uint8Array)) fail('bad')
      const parts = components(path)
      if (!parts) fail('notAllowed')
      const key = fold(parts), above = parts.slice(1).map((_, i) => fold(parts.slice(0, i + 1)))
      if (taken.has(key) || dirs.has(key) || above.some(a => taken.has(a))) fail('notAllowed')
      taken.add(key)
      above.forEach(a => dirs.add(a))
      total += bytes.length
      if (bytes.length > LIMITS.fileBytes || total > LIMITS.bytes) fail('tooBig')
    }
    const ids = new Set()
    for (const path of files.keys()) {
      const parts = path.split('/')
      if (parts[0] === 'Packs' && parts.length > 2 && parts[1].startsWith('pack-')) ids.add(parts[1])
    }
    const packs = [], skipped = []
    for (const id of [...ids].sort().slice(0, PACK.maxPacks)) {
      try { packs.push(readPack(id, files)) } catch (e) { skipped.push(id + ': ' + e.message) }
    }
    const str = k => typeof settings.get(k) === 'string' ? settings.get(k) : null
    let dogName = null
    const profile = settings.get('profile')
    if (profile instanceof Uint8Array && profile.length < 64 * 1024) {
      try { dogName = JSON.parse(new TextDecoder().decode(profile)).name || null } catch { /* not JSON: the default dog */ }
    }
    return { packs, skipped, chosen: { character: str('character'), catID: str('catID'), originalID: str('originalID'), style: str('renderStyle'), dogName } }
  }

  // MARK: one pack (CharacterPack.init)

  function oneLine(text, max) {
    // Control and format characters (bidi overrides and the like) out; joiners stay for emoji.
    return [...String(text).replace(/\p{Cc}/gu, ' ').replace(/(?![\u200c\u200d])\p{Cf}/gu, '').replace(/\s+/g, ' ').trim()].slice(0, max).join('').trim()
  }
  function cleanCries(raw) {
    if (!Array.isArray(raw)) return []
    return raw.filter(s => typeof s === 'string').map(s => oneLine(s, 99)).filter(s => [...s].length >= 1 && [...s].length <= 8).slice(0, 6)
  }
  const isObj = v => v !== null && typeof v === 'object' && !Array.isArray(v)

  function pngSize(b) {
    const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
    if (b.length < 33 || sig.some((v, i) => b[i] !== v) || String.fromCharCode(...b.subarray(12, 16)) !== 'IHDR') return null
    const dv = new DataView(b.buffer, b.byteOffset, b.byteLength)
    return [dv.getUint32(16), dv.getUint32(20)]
  }

  function readPack(id, files) {
    const bad = why => { throw new Error(why) }
    const json = files.get(`Packs/${id}/pack.json`)
    if (!json || json.length > PACK.jsonBytes) bad('pack.json missing or too big')
    let m
    try { m = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(json)) } catch { bad('pack.json unreadable') }
    if (!isObj(m) || m.version !== 1) bad('version')
    if (m.id !== id || !/^pack-[a-z0-9][a-z0-9-]{0,39}$/.test(id)) bad('id')
    if (typeof m.name !== 'string' || !isObj(m.frames)) bad('pack.json unreadable')
    const smooth = m.smooth === undefined ? false : m.smooth, density = m.density === undefined ? 2 : m.density
    if (typeof smooth !== 'boolean' || !Number.isInteger(density) || density < 1 || density > (smooth ? 8 : 2)) bad('density')
    const w = 34 * density, h = 20 * density
    const maxBytes = PACK.pngBytes * Math.max(4, density * density) / 4
    const name = oneLine(m.name, 99)
    if (!name || [...name].length > 40) bad('name')
    const takes = EXTRAS.flatMap(e => [2, 3, 4].map(i => `${e}.${i}`))
    const known = [...POSES, ...EXTRAS, ...takes]
    for (const [k, n] of Object.entries(m.frames)) if (!known.includes(k) || !Number.isInteger(n)) bad('unknown frame key')
    let seconds = {}
    if (m.seconds !== undefined) {
      if (!isObj(m.seconds)) bad('seconds')
      for (const [k, s] of Object.entries(m.seconds)) {
        if (![...POSES, ...EXTRAS].includes(k) || typeof s !== 'number' || s < 0.05 || s > 1) bad('seconds: known keys, 0.05...1.0')
      }
      seconds = m.seconds
    }
    const load = (key, lo, hi) => {
      const n = m.frames[key]
      if (!Number.isInteger(n) || n < lo || n > hi) bad(`'${key}' needs ${lo}...${hi} frames`)
      return Array.from({ length: n }, (_, i) => {
        const b = files.get(`Packs/${id}/frames/${key}-${i}.png`)
        const size = b && b.length <= maxBytes && pngSize(b)
        if (!size || size[0] !== w || size[1] !== h) bad(`${key}-${i}.png: not a ${w}x${h} PNG`)
        return b.slice()   // its own copy, so the whole file is not kept alive by one frame
      })
    }
    const frames = {}
    for (const pose of POSES) frames[pose] = load(pose, pose === 'lying' ? 1 : 2, 12)
    const loaded = new Set()
    for (const e of EXTRAS) {
      if (m.frames[e] === undefined) continue
      frames[e] = load(e, 2, 16)
      loaded.add(e)
      for (let i = 2; i <= PACK.maxTakes; i++) {
        const key = `${e}.${i}`
        if (m.frames[key] === undefined) break
        frames[key] = load(key, 2, 16)
        loaded.add(key)
      }
    }
    for (const k of Object.keys(m.frames)) if (!POSES.includes(k) && !loaded.has(k)) bad('takes go special, special.2, special.3 in order')
    const say = {}
    if (m.say !== undefined) {
      if (!isObj(m.say)) bad('say')
      for (const [k, lines] of Object.entries(m.say)) {
        if (!loaded.has(k) || !Array.isArray(lines)) bad('say: keys of the extras this pack has')
        const clean = lines.filter(s => typeof s === 'string').map(s => oneLine(s, PACK.lineLength)).filter(Boolean).slice(0, PACK.maxLines)
        if (clean.length) say[k] = clean
      }
    }
    const text = (v, max) => typeof v === 'string' && v ? [...v].slice(0, max).join('') : null
    return {
      id, name, density, smooth, seconds, say, frames,
      special: text(m.special, 40), blurb: text(m.blurb, 200),
      persona: PERSONAS.includes(m.persona) ? m.persona : null,
      cries: cleanCries(m.cries),
    }
  }

  const api = { parseBplist, readSetup, readPack, components, SetupError, LIMITS }
  if (typeof module === 'object' && module.exports) module.exports = api
  else root.CMSetup = api
})(typeof self !== 'undefined' ? self : this)
