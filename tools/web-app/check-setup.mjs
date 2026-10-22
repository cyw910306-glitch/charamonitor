// Self-check of web/app/setup.js: python3's plistlib writes a setup file with one good and one bad pack, setup.js
// must read the good one, skip the bad one, and refuse broken containers. Run: node tools/web-app/check-setup.mjs
import { execFileSync } from 'node:child_process'
import { createRequire } from 'node:module'
import assert from 'node:assert/strict'

const S = createRequire(import.meta.url)('../../web/app/setup.js')
const py = String.raw`
import plistlib, sys, json, struct, zlib, datetime
def png(w, h):
    chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    raw = b''.join(b'\0' + b'\xff\0\0\xff' * w for _ in range(h))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
mode = sys.argv[1]
files = {}
poses = ['lying', 'slowWalk', 'walk', 'fastWalk', 'run', 'sprint', 'exhausted']
frames = {p: 1 if p == 'lying' else 2 for p in poses}
frames.update({'special': 2, 'special.2': 2})
good = {'version': 1, 'id': 'pack-test', 'name': '\u202e테스트\u200b', 'frames': frames, 'persona': 'shy', 'cries': ['뾱', 'too long a cry'],
        'say': {'special': ['안녕\n하세요', '']}, 'seconds': {'walk': 0.2}}
files['Packs/pack-test/pack.json'] = json.dumps(good, ensure_ascii=False).encode()
for k, n in frames.items():
    for i in range(n): files['Packs/pack-test/frames/%s-%d.png' % (k, i)] = png(68, 40)
files['Packs/pack-bad/pack.json'] = json.dumps({'version': 1, 'id': 'pack-bad', 'name': 'x', 'frames': {'walk': 2}}).encode()
if mode == 'dotdot': files['Packs/../evil'] = b'x'
if mode == 'dup': files['Packs/PACK-TEST/pack.json'] = b'{}'
settings = {'character': 'original', 'originalID': 'pack-test'}
root = {'format': 3 if mode == 'newer' else 2, 'app': '3.0.2', 'created': datetime.datetime(2026, 10, 23), 'settings': settings, 'files': files}
sys.stdout.buffer.write(plistlib.dumps(root, fmt=plistlib.FMT_BINARY))
`
const make = mode => new Uint8Array(execFileSync('python3', ['-I', '-c', py, mode]))

const r = S.readSetup(make('ok'))
assert.equal(r.packs.length, 1)
const p = r.packs[0]
assert.equal(p.id, 'pack-test')
assert.equal(p.name, '테스트')   // the bidi override and zero width space are gone
assert.equal(p.persona, 'shy')
assert.deepEqual(p.cries, ['뾱'])
assert.deepEqual(p.say, { special: ['안녕 하세요'] })
assert.equal(p.frames.walk.length, 2)
assert.equal(p.frames['special.2'].length, 2)
assert.equal(r.skipped.length, 1)
assert.match(r.skipped[0], /pack-bad/)
assert.equal(r.chosen.originalID, 'pack-test')
for (const [mode, code] of [['dotdot', 'notAllowed'], ['dup', 'notAllowed'], ['newer', 'newer']]) {
  assert.throws(() => S.readSetup(make(mode)), e => e.code === code, mode)
}
const ok = make('ok')
assert.throws(() => S.readSetup(ok.slice(0, ok.length - 40)), e => e.code === 'bad', 'truncated')
assert.throws(() => S.readSetup(new TextEncoder().encode('<?xml version="1.0"?><plist></plist>' + ' '.repeat(40))), e => e.code === 'bad', 'xml')
assert.equal(S.components('Packs/a/../b'), null)
assert.equal(S.components('Other/a'), null)
// Hostile plists: one 10 KB string behind many refs (or many objects at its offset), and an array header bigger than
// the object limit. Each must finish fast with a small heap, not decode the string again and again.
function bomb(strLen, n, { sameOffset = false, claim = n } = {}) {
  const be = (v, k) => { const b = Buffer.alloc(k); b.writeUIntBE(v, 0, k); return b }
  const refSize = sameOffset ? 4 : 1, objs = sameOffset ? n + 1 : 2
  const str = Buffer.concat([Buffer.from([0x5f, 0x12]), be(strLen, 4), Buffer.alloc(strLen, 0x41)])
  const refs = Buffer.concat(Array.from({ length: n }, (_, i) => be(sameOffset ? i + 1 : 1, refSize)))
  const arr = Buffer.concat([Buffer.from([0xaf, 0x12]), be(claim, 4), refs])
  const arrAt = 8 + str.length, table = arrAt + arr.length
  // object 0 is the array (top); objects 1... (or just 1) all sit at the string's offset
  const offs = Buffer.concat([be(arrAt, 4), ...Array.from({ length: objs - 1 }, () => be(8, 4))])
  const tr = Buffer.alloc(32); tr[6] = 4; tr[7] = refSize; tr.writeBigUInt64BE(BigInt(objs), 8); tr.writeBigUInt64BE(0n, 16); tr.writeBigUInt64BE(BigInt(table), 24)
  return new Uint8Array(Buffer.concat([Buffer.from('bplist00'), str, arr, offs, tr]))
}
{
  const t = Date.now()
  const shared = S.parseBplist(bomb(10000, 20000))   // 20,000 refs to one string: decoded once
  assert.equal(shared.length, 20000)
  assert.throws(() => S.parseBplist(bomb(10000, 20000, { sameOffset: true })), e => e.code === 'bad', 'same offset')
  assert.throws(() => S.parseBplist(bomb(10, 0, { claim: 300000 })), e => e.code === 'bad', 'huge array header')
  assert.ok(Date.now() - t < 3000, 'bombs took too long')
}
console.log('setup.js check: ok')
