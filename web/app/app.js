// 캐릭모니터 웹 앱: the menu bar friend on a phone. Vanilla, no build step, nothing leaves the device.
// Ports of the Mac app: reactions and the click combo (App/DesktopKit.swift), meadow lines (App/MeadowFriends.swift),
// the made cries (App/FriendCry.swift), the buddy's gaits (App/CursorBuddy.swift), 말투 (Assistant/AssistantPrompt.swift).
'use strict'

// MARK: prefs, strings

const store = {
  get(k, d) { try { const v = localStorage.getItem('cm.' + k); return v === null ? d : JSON.parse(v) } catch { return d } },
  set(k, v) { try { localStorage.setItem('cm.' + k, JSON.stringify(v)) } catch { /* private mode: this session only */ } },
}
const prefs = { sound: store.get('sound', true), vibe: store.get('vibe', true), lang: store.get('lang', 'auto') }
const LANG = () => prefs.lang !== 'auto' ? prefs.lang : (navigator.language || 'ko').toLowerCase().startsWith('ko') ? 'ko' : 'en'

const STR = {
  ko: {
    title: '캐릭모니터 웹 앱', hint: '톡 눌러 보세요. 꾹 누르면 쓰다듬고, 끌어서 던질 수도 있어요.',
    friends: '친구', play: '놀이', focus: '집중', settings: '설정', close: '닫기',
    pickTitle: '친구 고르기', dogs: '강아지', cats: '고양이', originals: '오리지널', mine: '내 캐릭터',
    importBtn: '내 설정 파일 가져오기',
    importNote: '맥 앱에서 내보낸 .charamonitor 파일 속 내 캐릭터를 이 기기에 넣어요. 파일은 이 기기 안에서만 읽고 어디에도 보내지 않아요.',
    importing: '설정 파일을 읽는 중이에요…', imported: '캐릭터 {n}개를 가져왔어요.', importedNone: '파일에 가져올 캐릭터 팩이 없어요.',
    importSkipped: '{n}개는 형식이 맞지 않아 건너뛰었어요.',
    bad: '캐릭모니터 설정 파일이 아니거나 망가진 파일이에요.', newer: '더 새 캐릭모니터에서 만든 파일이에요. 맥 앱을 업데이트한 뒤 다시 내보내 주세요.',
    notAllowed: '파일 안에 들어 있으면 안 되는 항목이 있어서 가져오지 않았어요.', tooBig: '너무 커요. 웹 앱에서는 설정 파일을 64MB까지만 읽을 수 있어요.',
    unreadable: '파일을 읽지 못했어요. 아이클라우드 파일이라면 다 내려받은 뒤 다시 골라 주세요.',
    noStore: '이 브라우저에 저장하지 못했어요. 저장 공간을 확인해 주세요.',
    games: '미니 게임', starTitle: '별 줍기', starDesc: '60초 동안 발판을 뛰어다니며 별을 모아요',
    moleTitle: '두더지잡기', moleDesc: '30초 동안 쏙 나오는 친구를 톡 눌러요', best: '최고 {n}',
    starHelp: '왼쪽, 오른쪽을 꾹 눌러 움직이고, 위쪽이나 점프를 눌러 뛰어요', moleHelp: '구멍에서 나오는 친구를 톡!',
    jump: '점프', again: '다시 하기', starResult: '별 {n}개를 모았어요!', moleResult: '{n}번 잡았어요!', newBest: '최고 기록이에요!', bestWas: '최고 기록 {n}',
    focusTitle: '집중 타이머', focusDesc: '친구가 옆에서 같이 공부해요. 끝나면 알려 주고, 화면을 껐다면 다시 열었을 때 알려 줘요.', minutes: '분',
    focusKeep: '화면을 꺼도 끝나는 시각은 그대로예요. 다시 열면 바로 맞춰져요.', focusing: '집중 중', stop: '그만하기',
    sound: '소리', vibration: '진동', language: '언어', auto: '자동', deletePacks: '가져온 캐릭터 지우기', reset: '모든 데이터 지우기',
    deleteConfirm: '가져온 캐릭터를 이 기기에서 모두 지울까요?', resetConfirm: '고른 친구, 최고 기록, 가져온 캐릭터를 이 기기에서 모두 지울까요?',
    deleted: '지웠어요.', privacy: '모든 것은 이 기기 안에만 있어요. 분석 도구도, 바깥으로 나가는 요청도 없어요.', macApp: '맥 앱 보러 가기',
    installTitle: '홈 화면에 추가하면 앱처럼 쓸 수 있어요', installStep1: '사파리의 공유 버튼을 눌러요', installStep2: '홈 화면에 추가를 골라요',
    soundOn: '소리 켜짐', soundOff: '소리 꺼짐', charging: '충전 중',
  },
  en: {
    title: 'CharaMonitor web app', hint: 'Tap me. Press and hold to pet, or drag and fling.',
    friends: 'Friends', play: 'Play', focus: 'Focus', settings: 'Settings', close: 'Close',
    pickTitle: 'Pick a friend', dogs: 'Dogs', cats: 'Cats', originals: 'Originals', mine: 'My characters',
    importBtn: 'Import my setup file',
    importNote: 'Brings your own characters from a .charamonitor file exported by the Mac app. The file is read on this device only and sent nowhere.',
    importing: 'Reading your setup file…', imported: 'Imported {n} characters.', importedNone: 'No character packs to import in this file.',
    importSkipped: 'Skipped {n} that did not match the format.',
    bad: 'This is not a CharaMonitor setup file, or it is damaged.', newer: 'This file is from a newer CharaMonitor. Update the Mac app and export again.',
    notAllowed: 'The file holds something it should not, so nothing was imported.', tooBig: 'Too big. The web app reads setup files up to 64 MB.',
    unreadable: 'Could not read the file. If it is in iCloud, let it finish downloading and pick it again.',
    noStore: 'Could not save in this browser. Check the free space.',
    games: 'Mini games', starTitle: 'Star Catch', starDesc: 'Hop across platforms and collect stars for 60 seconds',
    moleTitle: 'Whack-a-Friend', moleDesc: 'Tap your friend as it pops up, 30 seconds', best: 'Best {n}',
    starHelp: 'Hold left or right to move, tap the top or Jump to jump', moleHelp: 'Tap your friend when it pops up!',
    jump: 'Jump', again: 'Play again', starResult: 'You got {n} stars!', moleResult: 'Caught {n} times!', newBest: 'New best!', bestWas: 'Best {n}',
    focusTitle: 'Focus timer', focusDesc: 'Your friend studies next to you and tells you when time is up, or when you come back if the screen was off.', minutes: 'min',
    focusKeep: 'The end time holds even with the screen off. It catches up when you come back.', focusing: 'Focusing', stop: 'Stop',
    sound: 'Sound', vibration: 'Vibration', language: 'Language', auto: 'Auto', deletePacks: 'Delete imported characters', reset: 'Erase all data',
    deleteConfirm: 'Delete all imported characters from this device?', resetConfirm: 'Erase your friend, best scores and imported characters from this device?',
    deleted: 'Deleted.', privacy: 'Everything stays on this device. No analytics, no outside requests.', macApp: 'Get the Mac app',
    installTitle: 'Add it to your Home Screen to use it like an app', installStep1: "Tap Safari's Share button", installStep2: 'Choose Add to Home Screen',
    soundOn: 'Sound on', soundOff: 'Sound off', charging: 'Charging',
  },
}
const T = (k, n) => (STR[LANG()][k] ?? STR.ko[k] ?? k).replace('{n}', n)

// What a friend says (MeadowReaction.lines, petLines; 해요체 like the Mac app), and the 말투 flavours (PersonaStyle).
const LINES = {
  ko: {
    dizzy: ['어질어질…', '세상이 빙글빙글 돌아요', '눈앞이 핑핑 돌아요'], pout: ['그만 눌러요, 흥!', '이제 안 놀아 줄 거예요'],
    eat: ['냠냠, 맛있어요', '간식 먹는 중이에요'], sleep: ['잠깐 앉아서 쉴래요', '풀밭이 폭신해요'],
    tap: ['헤헤, 불렀어요?', '안녕! 오늘도 같이 놀아요', '간지러워요', '뭐 하고 있어요?', '저 여기 있어요!'],
    pet: ['쓰담쓰담 좋아요', '헤헤, 기분 좋아요', '더 쓰다듬어 주세요'],
    fly: ['우와아, 날아간다!', '깜짝이야!'], hello: ['안녕! 오늘도 같이 놀아요', '반가워요!'], hungry: ['배고파요…', '맛있는 거 없어요?'],
    study: ['열심히 하고 있어요', '조금만 더 힘내요', '옆에서 같이 할게요'], done: ['다 했어요! 정말 수고했어요', '끝! 잠깐 쉬어요'],
    night: ['쿨쿨…', '졸려요…'],
  },
  en: {
    dizzy: ['So dizzy…', 'The world is going round and round', 'Everything is spinning'], pout: ['Stop poking me, hmph!', "I'm not playing with you anymore"],
    eat: ['Nom nom, yummy', "I'm having a snack"], sleep: ["I'll sit and rest a bit", 'The grass is so soft'],
    tap: ['Hehe, you called?', "Hi! Let's play today too", 'That tickles', 'What are you up to?', "I'm right here!"],
    pet: ['I love being petted', 'Hehe, that feels nice', 'Pet me some more'],
    fly: ['Whoa, I am flying!', 'Eek!'], hello: ["Hi! Let's play today too", 'Nice to see you!'], hungry: ["I'm hungry…", 'Got anything tasty?'],
    study: ["I'm working hard", 'Just a little more', "I'll keep you company"], done: ['All done! Great work', 'Finished! Take a little break'],
    night: ['Zzz…', 'So sleepy…'],
  },
}
const FLAVOR = {
  ko: { leads: { friendly: ['있지, ', '저기, '], shy: ['저, 저기… ', '그, 그게… '], proud: ['흥, ', '뭐, '], bright: ['좋아! ', '자! '] },
        tails: { friendly: [' 헤헤', ' 히히'], shy: [' (부끄)', ' …헤헤'], proud: [' 에헴', ' 흥'], bright: [' 파이팅!', ' 아자!'] } },
  en: { leads: { friendly: ['Hey! ', 'So… '], shy: ['Um, uh… ', 'W-well… '], proud: ['Hmph. ', 'Well… '], bright: ['Okay! ', 'Right! '] },
        tails: { friendly: [' hehe', ' heehee'], shy: [' (blush)', ' …hehe'], proud: [' Ahem.', ' Hmph.'], bright: [' You got this!', " Let's go!"] } },
}
const NEUTRAL_CRIES = [{ ko: '음!', en: 'Hm!' }, { ko: '오!', en: 'Oh!' }, { ko: '흠흠', en: 'Hmm' }]

const rand = (a, b) => a + Math.random() * (b - a)
const lastPick = {}
// LinePick: never the same one twice in a row for `key`.
function pick(key, list) {
  if (!list || !list.length) return ''
  let i = Math.floor(Math.random() * list.length)
  if (list.length > 1 && list[i] === lastPick[key]) i = (i + 1) % list.length
  return (lastPick[key] = list[i])
}
const line = key => pick('line.' + key, LINES[LANG()][key])

// MARK: storage (IndexedDB, shared with ../my-setup.html)

function idb() {
  return new Promise((resolve, reject) => {
    const r = indexedDB.open('charamonitor-web', 1)
    r.onupgradeneeded = () => r.result.createObjectStore('kv')
    r.onsuccess = () => resolve(r.result)
    r.onerror = () => reject(r.error)
  })
}
async function kv(mode, fn) {
  const db = await idb()
  return new Promise((resolve, reject) => {
    const tx = db.transaction('kv', mode), req = fn(tx.objectStore('kv'))
    let out
    if (req) req.onsuccess = () => { out = req.result }
    tx.oncomplete = () => { db.close(); resolve(out) }
    tx.onerror = tx.onabort = () => { db.close(); reject(tx.error) }
  })
}
// A pack is two records: 'pack:<id>' (name, frame counts, the first walk frame for its tile) read on every launch, and
// 'frames:<id>' (every frame) read only when the friend comes on stage.
const PACK_KEYS = () => IDBKeyRange.bound('pack:', 'pack:￿')
const FRAME_KEYS = () => IDBKeyRange.bound('frames:', 'frames:￿')

// MARK: characters

const FW = 34, FH = 20
const DEFAULT_S = { lying: 0.6, slowWalk: 0.2, walk: 0.141, fastWalk: 0.108, run: 0.08, sprint: 0.063, exhausted: 0.05, hungry: 0.38, eat: 0.22, special: 0.12 }
let builtins = [], packs = [], current = null, rig = null
const name = ch => ch.name[LANG()] || ch.name.ko
const allChars = () => [...builtins, ...packs]
const findChar = id => allChars().find(c => c.id === id)

function packChar(p) {
  const rows = {}
  for (const [key, n] of Object.entries(p.counts)) rows[key] = { n, s: p.seconds[key.split('.')[0]] ?? DEFAULT_S[key.split('.')[0]] }
  return { id: p.id, kind: 'pack', name: { ko: p.name, en: p.name }, persona: p.persona || 'friendly', voice: 'chirp',
           cries: p.cries.length ? p.cries.map(c => ({ ko: c, en: c })) : NEUTRAL_CRIES, say: p.say || {}, rows, smooth: p.smooth, record: p }
}

async function loadBuiltins() {
  const r = await fetch('sprites/index.json')
  const ix = await r.json()
  builtins = ix.characters.map(c => {
    const rows = {}
    c.rows.forEach((row, i) => { rows[row.key] = { n: row.n, s: row.s, y: i } })
    return { ...c, rows, say: {} }
  })
}
async function loadPacks() {
  try { packs = ((await kv('readonly', st => st.getAll(PACK_KEYS()))) || []).map(packChar) } catch { packs = [] }
}

function loadImage(src) {
  return new Promise((resolve, reject) => { const i = new Image(); i.onload = () => resolve(i); i.onerror = reject; i.src = src })
}
async function blobImage(buf) {
  const blob = new Blob([buf], { type: 'image/png' })
  if (self.createImageBitmap) return createImageBitmap(blob)
  const url = URL.createObjectURL(blob)
  try { return await loadImage(url) } finally { setTimeout(() => URL.revokeObjectURL(url), 1000) }
}
// A pack frame: pixel art gets hard alpha like the Mac app (CharacterPack.png), illustrations keep their own.
async function packFrame(buf, smooth) {
  const img = await blobImage(buf)
  if (smooth) return { img, sx: 0, sy: 0, sw: img.width, sh: img.height }
  const c = document.createElement('canvas')
  c.width = img.width; c.height = img.height
  const x = c.getContext('2d', { willReadFrequently: true })
  x.drawImage(img, 0, 0)
  const d = x.getImageData(0, 0, c.width, c.height)
  for (let i = 3; i < d.data.length; i += 4) d.data[i] = d.data[i] >= 128 ? 255 : 0
  x.putImageData(d, 0, 0)
  return { img: c, sx: 0, sy: 0, sw: c.width, sh: c.height }
}

const rigs = new Map()
async function loadRig(ch) {
  if (rigs.has(ch.id)) return rigs.get(ch.id)
  const out = { smooth: !!ch.smooth }
  if (ch.sheet) {
    const img = await loadImage('sprites/' + ch.sheet)
    // Each cell in its own canvas: a rotated draw straight from the sheet picks up the next cell's edge pixels.
    const cell = (c, y) => {
      const k = document.createElement('canvas')
      k.width = FW; k.height = FH
      k.getContext('2d').drawImage(img, c * FW, y * FH, FW, FH, 0, 0, FW, FH)
      return { img: k, sx: 0, sy: 0, sw: FW, sh: FH }
    }
    for (const [key, row] of Object.entries(ch.rows)) {
      out[key] = { s: row.s, f: Array.from({ length: row.n }, (_, c) => cell(c, row.y)) }
    }
  } else {
    const frames = await kv('readonly', st => st.get('frames:' + ch.id))
    if (!frames) throw new Error('no frames')
    for (const [key, list] of Object.entries(frames)) {
      out[key] = { s: ch.rows[key].s, f: await Promise.all(list.map(b => packFrame(b, ch.smooth))) }
    }
  }
  if (rigs.size > 4) rigs.delete(rigs.keys().next().value)   // ponytail: a handful of decoded friends; HD packs are big
  rigs.set(ch.id, out)
  return out
}

// Gaits to rows (BuddyGait.frames): a row the character lacks falls back along the list.
const GAIT_ROWS = {
  walk: ['walk'], slowWalk: ['slowWalk', 'walk'], run: ['run', 'walk'], sleep: ['lying'], stand: ['walk'], study: ['walk'],
  dizzy: ['exhausted', 'walk'], sulk: ['hungry', 'lying'], special: ['special', 'eat', 'walk'], eat: ['eat', 'walk'],
  hungry: ['hungry', 'walk'], held: ['exhausted', 'run', 'walk'], fly: ['run', 'walk'],
}
const STILL = new Set(['stand', 'study'])
// rAF time can trail performance.now() by a frame: never a negative index.
const frameAt = (ms, row) => Math.floor(Math.max(0, ms) / 1000 / row.s) % row.f.length
function rowFor(r, gait, take) {
  if (take && r[take]) return r[take]
  for (const k of GAIT_ROWS[gait] || [gait, 'walk']) if (r[k]) return r[k]
  return r.walk
}
// Takes of an extra: "special", "special.2" ...; one at random, not the last one.
function takeOf(ch, key) {
  const list = Object.keys(ch.rows).filter(k => k === key || k.startsWith(key + '.'))
  return list.length ? pick('take.' + ch.id + key, list) : null
}

// MARK: sound (FriendCry.make, WebAudio)

let ac = null, cryUntil = 0
function unlockAudio() {
  if (!ac) {
    const AC = window.AudioContext || window.webkitAudioContext
    if (!AC) return
    ac = new AC()
    const b = ac.createBuffer(1, 1, 22050), s = ac.createBufferSource()   // iOS: a silent sound inside the gesture
    s.buffer = b; s.connect(ac.destination); s.start(0)
  }
  if (ac.state !== 'running') ac.resume().catch(() => {})   // 'suspended', or iOS 'interrupted' after a call or Siri
}
function fnv(id) {
  let h = 2166136261
  for (const b of new TextEncoder().encode(id)) h = Math.imul(h ^ b, 16777619) >>> 0
  return h
}
const cryCache = new Map()
function makeCry(voice, kind, variant) {
  const key = voice + kind + variant
  if (cryCache.has(key)) return cryCache.get(key)
  const rate = 22050
  let base, harmonics
  if (voice === 'bark') [base, harmonics] = [480, [1, 0.7, 0.45, 0.3]]
  else if (voice === 'meow') [base, harmonics] = [620, [1, 0.5, 0.25]]
  else [base, harmonics] = [520 + fnv(voice) % 581, [1, 0.25]]
  const f0 = base * [1, 1.06, 0.94][variant % 3]
  let seconds, pitch, amp = u => Math.pow(Math.sin(Math.PI * u), 0.7)
  const half = u => u < 0.5 ? u * 2 : u * 2 - 1
  if (kind === 'normal' && voice === 'bark') {
    seconds = 0.26; pitch = u => 1.25 - 0.45 * half(u)
    amp = u => { const x = half(u) / 0.8; return x < 1 ? Math.pow(Math.sin(Math.PI * x), 0.5) : 0 }
  } else if (kind === 'normal' && voice === 'meow') {
    seconds = 0.42; pitch = u => (u < 0.4 ? 1 + u : 1.4 - 0.55 * (u - 0.4) / 0.6) * (1 + 0.03 * Math.sin(2 * Math.PI * 6 * 0.42 * u))
  } else if (kind === 'normal') { seconds = 0.2; pitch = u => 1 + 0.6 * Math.sin(Math.PI * u / 2) }
  else if (kind === 'dizzy') { seconds = 0.45; pitch = u => (1.15 - 0.45 * u) * (1 + 0.08 * Math.sin(2 * Math.PI * 5 * u)) }
  else if (kind === 'sulk') { seconds = 0.16; pitch = u => 0.72 - 0.12 * u }
  else { seconds = 0.3; pitch = u => 0.8 + 0.7 * u * u }
  const n = Math.floor(seconds * rate), total = harmonics.reduce((a, b) => a + b, 0)
  const buf = ac.createBuffer(1, n, rate), out = buf.getChannelData(0)
  let phase = 0
  for (let i = 0; i < n; i++) {
    const u = i / n
    phase += 2 * Math.PI * f0 * pitch(u) / rate
    let v = 0
    harmonics.forEach((a, k) => { v += a * Math.sin((k + 1) * phase) })
    out[i] = Math.max(-1, Math.min(1, v / total * amp(u))) * 0.8
  }
  cryCache.set(key, buf)
  return buf
}
function cry(kind = 'normal') {
  if (!prefs.sound || !ac || !current || ac.state !== 'running' || ac.currentTime < cryUntil) return
  const voice = current.voice === 'chirp' ? current.id : current.voice
  const buf = makeCry(voice, kind, kind === 'normal' ? Math.floor(Math.random() * 3) : 0)
  const s = ac.createBufferSource(), g = ac.createGain()
  g.gain.value = 0.55
  s.buffer = buf; s.connect(g); g.connect(ac.destination); s.start()
  cryUntil = ac.currentTime + buf.duration
}
function chime() {
  if (!prefs.sound || !ac) return
  const t = ac.currentTime + 0.05
  ;[880, 1108.7, 1318.5, 1760].forEach((f, i) => {
    const o = ac.createOscillator(), g = ac.createGain()
    o.type = 'sine'; o.frequency.value = f
    g.gain.setValueAtTime(0, t + i * 0.16)
    g.gain.linearRampToValueAtTime(0.22, t + i * 0.16 + 0.02)
    g.gain.exponentialRampToValueAtTime(0.001, t + i * 0.16 + 1.1)
    o.connect(g); g.connect(ac.destination); o.start(t + i * 0.16); o.stop(t + i * 0.16 + 1.2)
  })
}
const vibrate = p => { if (prefs.vibe && navigator.vibrate) navigator.vibrate(p) }

// MARK: reactions (Reaction, ClickCombo)

const DEG = Math.PI / 180
const REACT = {
  hearts: { d: 1.2, gait: 'special', mark: ['♥', '#E8558C'] },
  jump: { d: 0.9, gait: 'stand' },
  spin: { d: 1.0, gait: 'stand', spins: true },
  blush: { d: 1.4, gait: 'special', mark: ['///', '#E8558C'] },
  surprised: { d: 1.0, gait: 'stand', mark: ['!', '#F08C2E'] },
  giggle: { d: 1.2, gait: 'special', mark: ['♪', '#9B6BD6'] },
  sneeze: { d: 1.2, gait: 'stand', mark: [{ ko: '에취!', en: 'Achoo!' }, '#2FA6B5'] },
  dizzy: { d: 2.2, gait: 'dizzy', mark: ['@', '#5B63D6'] },
  pout: { d: 2.2, gait: 'stand', mark: [{ ko: '흥!', en: 'Hmph!' }, '#D9483B'] },
}
const CUTE = ['hearts', 'jump', 'spin', 'blush', 'surprised', 'giggle', 'sneeze']
function reactPose(r, t) {
  const R = REACT[r]
  if (!R || t < 0 || t >= R.d || reducedMotion) return [0, 0, 1, 1]
  const arc = over => { if (t >= over) return 0; const u = t / over; return 4 * u * (1 - u) }
  switch (r) {
    case 'hearts': return [arc(0.4) * 0.15, 0, 1, 1]
    case 'jump': return [arc(0.6) * 0.6, 0, 1, 1]
    case 'spin': return t < 0.6 ? [arc(0.6) * 0.15, 2 * Math.PI * t / 0.6, 1, 1] : [0, 0, 1, 1]
    case 'surprised': return [arc(0.3) * 0.25, 0, t < 0.3 ? 0.94 : 1, t < 0.3 ? 1.08 : 1]
    case 'giggle': return [0, 4 * DEG * Math.sin(t * 40), 1, 1]
    case 'blush': return [0, 3 * DEG * Math.sin(t * 8), 1, 0.97]
    case 'dizzy': return [0, 8 * DEG * Math.sin(t * 6), 1, 1]
    case 'sneeze': {
      if (t < 0.5) { const u = t / 0.5; return [0, 0, 1 + 0.05 * u, 1 - 0.15 * u] }
      const v = Math.max(0, 1 - (t - 0.5) / 0.3); return [0, 0, 1 + 0.1 * v, 1 - 0.1 * v]
    }
    default: return [0, 0, 1, 1]
  }
}
const combo = { count: 0, last: -10 }
function comboClick(t) {
  combo.count = t - combo.last <= 0.7 ? combo.count + 1 : 1
  combo.last = t
  if (combo.count === 3) return 'dizzy'
  if (combo.count >= 5) { combo.count = 0; return 'pout' }
  return pick('react', CUTE)
}
const cryKind = r => r === 'dizzy' ? 'dizzy' : r === 'pout' ? 'sulk' : r === 'jump' || r === 'spin' ? 'hop' : 'normal'

// 말투 (Persona.dress): the 울음소리 style puts a sound first, the others now and then a lead or a tail.
function dress(text) {
  const L = LANG(), style = current?.persona || 'friendly'
  const cries = (current?.cries?.length ? current.cries : NEUTRAL_CRIES).map(c => c[L] || c.ko)
  if (style === 'cry') return `${pick('cry', cries)} (${text})`
  if (Math.random() >= 0.25) return text
  const lead = Math.random() < 0.5, list = FLAVOR[L][lead ? 'leads' : 'tails'][style] || []
  if (!list.length) return text
  const item = list[Math.floor(Math.random() * list.length)]
  return lead ? item + text : text + item
}

// MARK: the stage

const $ = s => document.querySelector(s)
const stage = $('#stage'), cv = $('#cv'), ctx = cv.getContext('2d'), bubbleEl = $('#bubble')
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches
let SW = 0, SH = 0, DPR = 1, K = 6, groundY = 0
const P = { x: 0, y: 0, vx: 0, vy: 0, face: 1, mode: 'idle', gait: 'stand', take: null, gaitT: 0, until: 0, target: null, speed: 0,
            react: null, reactT: 0, angle: 0, impact: 0, lastInput: 0, petNext: 0, held: null }
const particles = []
let bubble = null

function resize() {
  const r = stage.getBoundingClientRect()
  SW = r.width; SH = r.height; DPR = Math.min(3, window.devicePixelRatio || 1)
  cv.width = Math.round(SW * DPR); cv.height = Math.round(SH * DPR)
  K = Math.max(3, Math.min(9, Math.floor(Math.min(SW * 0.55 / FW, SH * 0.42 / FH))))
  groundY = SH * 0.86
  if (!P.x) P.x = SW / 2
  P.x = Math.max(FW * K / 2, Math.min(SW - FW * K / 2, P.x))
  dirty = true
}

function setGait(gait, ms, take = null) {
  if (gait === 'study') {   // the desk sits beside the friend and is wider than it: keep both on screen
    const m = FH * K * 0.65 + FW * K * 0.18 + 8
    P.x = SW > 2 * m ? Math.max(m, Math.min(SW - m, P.x)) : SW / 2
  }
  P.gait = gait; P.take = take; P.gaitT = performance.now(); P.until = P.gaitT + ms; P.target = null
}
function walkTo(x, gait = 'walk') {
  const half = FW * K / 2
  x = Math.max(half, Math.min(SW - half, x))
  setGait(gait, 20000)
  P.target = x
  P.speed = { slowWalk: 0.9, walk: 1.8, run: 5 }[gait] * K * 10
  P.face = x >= P.x ? 1 : -1
}
function playExtra(key) {
  const take = takeOf(current, key)
  if (!take) return setGait('stand', 1500)
  const row = rig[take]
  setGait(key, Math.max(1600, row.f.length * row.s * 1000 * 2), take)
  const own = current.say[take]
  if (own?.length) say(pick('say.' + take, own))
  else if (key === 'eat' && Math.random() < 0.5) say(dress(line('eat')))
  else if (key === 'hungry' && Math.random() < 0.5) say(dress(line('hungry')))
}
function nextIdle(t) {
  const h = new Date().getHours(), night = h >= 23 || h < 7, bored = t - P.lastInput > 90000
  if ((night || bored) && Math.random() < 0.8) { setGait('sleep', rand(10000, 20000)); if (Math.random() < 0.2) say(line('night')); return }
  if (battery.level !== null && !battery.charging && battery.level < 0.2 && Math.random() < 0.35) return playExtra('hungry')
  if (battery.charging && Math.random() < 0.25) return playExtra('eat')
  const r = Math.random()
  if (r < 0.42) walkTo(rand(0, SW), 'walk')
  else if (r < 0.52) walkTo(rand(0, SW), 'slowWalk')
  else if (r < 0.58) walkTo(P.x < SW / 2 ? SW : 0, 'run')
  else if (r < 0.78) setGait('stand', rand(1500, 4000))
  else if (r < 0.86) setGait('sleep', rand(5000, 9000))
  else if (r < 0.93 && rig.special) playExtra('special')
  else playExtra('eat')
}

function say(text, ms = 2600) {
  if (!text) return
  bubble = { text, until: performance.now() + ms }
  bubbleEl.textContent = text
  bubbleEl.hidden = false
  dirty = true
}
function mark(text, color) {
  if (typeof text === 'object') text = text[LANG()] || text.ko
  for (let i = particles.length - 1; i >= 0; i--) if (particles[i].mark) particles.splice(i, 1)   // quick taps: one mark at a time
  particles.push({ mark: true, text, color, x: P.x + P.face * FW * K * 0.42, y: groundY - P.y - FH * K * 0.8, vy: -24, t0: performance.now(), d: 900, size: Math.max(18, K * 4) })
}
function heart() {
  particles.push({ text: '♥', color: '#E8558C', x: P.x + rand(-FW * K * 0.3, FW * K * 0.3), y: groundY - P.y - FH * K * 0.9, vy: -70,
                   t0: performance.now(), d: 1100, size: Math.max(16, K * 3.4) })
}

function startReaction(r, t) {
  P.mode = 'react'; P.react = r; P.reactT = t
  const R = REACT[r]
  setGait(R.gait, R.d * 1000, R.gait === 'special' ? takeOf(current, 'special') : null)
  if (r === 'pout') P.face = -P.face   // its back turned
  if (R.mark) mark(R.mark[0], R.mark[1])
  const own = R.gait === 'special' && P.take && current.say[P.take]
  const comboLine = r === 'dizzy' || r === 'pout'
  say(comboLine ? line(r) : own?.length ? pick('say.' + P.take, own) : dress(line('tap')))
  cry(cryKind(r))
  if (r === 'dizzy') vibrate(30)
}
function endReaction() {
  if (P.react === 'pout') P.face = -P.face
  P.mode = focus.end ? 'study' : 'idle'; P.react = null
  setGait('stand', rand(800, 1800))
}

let dirty = true, lastT = 0, lastKey = ''
function loop(now) {
  requestAnimationFrame(loop)
  if (!rig || document.hidden || gameOn) return
  const dt = Math.min(0.05, (now - (lastT || now)) / 1000)
  lastT = now
  update(dt, now)
  draw(now)
}

function update(dt, t) {
  const W = FW * K, H = FH * K, half = W / 2
  if (P.mode === 'held') {
    const h = P.held
    P.x += (h.x - P.x) * Math.min(1, dt * 18)
    const feet = h.y + H * 0.85
    P.y = Math.max(0, groundY - feet)
    P.angle = reducedMotion ? 0 : Math.max(-0.5, Math.min(0.5, -h.vx * 0.0006))
    dirty = true
    return
  }
  if (P.mode === 'fly') {
    P.vy -= 2600 * dt
    P.x += P.vx * dt; P.y += P.vy * dt
    if (!reducedMotion) P.angle += P.vx * dt * 0.012
    if (P.x < half) { P.x = half; P.vx = Math.abs(P.vx) * 0.5 }
    if (P.x > SW - half) { P.x = SW - half; P.vx = -Math.abs(P.vx) * 0.5 }
    const top = groundY - H
    if (P.y > top) { P.y = top; P.vy = -Math.abs(P.vy) * 0.3 }
    if (P.y <= 0 && P.vy < 0) {
      P.impact = Math.max(P.impact, -P.vy)
      P.y = 0; P.vy = -P.vy * 0.45; P.vx *= 0.7; P.angle = 0
      if (P.vy < 160) {
        P.vy = 0; P.vx = 0; P.mode = 'idle'
        if (P.impact > 1500) startReaction('dizzy', t / 1000)
        else { setGait('stand', 900); cry('hop') }
        P.impact = 0
      } else cry('hop')
    }
    dirty = true
    return
  }
  if (P.mode === 'pet') {
    if (t >= P.petNext) { heart(); P.petNext = t + 260 }
    return
  }
  if (P.mode === 'react') {
    if (t / 1000 - P.reactT >= REACT[P.react].d) endReaction()
    return
  }
  if (P.mode === 'study') return
  if (P.target !== null) {
    const d = P.target - P.x, step = P.speed * dt
    if (Math.abs(d) <= step) { P.x = P.target; P.target = null; setGait('stand', rand(1200, 3500)) }
    else { P.x += Math.sign(d) * step; P.face = Math.sign(d) }
    dirty = true
  } else if (t >= P.until) nextIdle(t)
}

function drawDesk(x, footY, H) {
  const w = H * 1.3, top = footY - H * 0.32, u = Math.max(2, K)
  ctx.fillStyle = '#F3B3C2'
  ctx.fillRect(x - w / 2, top, w, u * 1.6)
  ctx.fillStyle = '#D98AA0'
  ctx.fillRect(x - w / 2 + u, top + u * 1.6, u, footY - top - u * 1.6)
  ctx.fillRect(x + w / 2 - 2 * u, top + u * 1.6, u, footY - top - u * 1.6)
  ctx.fillStyle = '#FFFFFF'
  ctx.fillRect(x - u * 5, top - u * 1.4, u * 4.6, u * 1.4)
  ctx.fillRect(x + u * 0.4, top - u * 1.4, u * 4.6, u * 1.4)
  ctx.fillStyle = '#9C8D84'
  ctx.fillRect(x - u * 0.2, top - u * 1.6, u * 0.4, u * 1.6)
}

function draw(t) {
  const W = FW * K, H = FH * K
  const row = rowFor(rig, P.gait, P.take)
  const still = STILL.has(P.gait) || (P.mode === 'react' && P.gait === 'stand')
  const idx = still ? 0 : frameAt(t - P.gaitT, row)
  const pose = P.mode === 'react' ? reactPose(P.react, t / 1000 - P.reactT) : [0, 0, 1, 1]
  const angle = P.mode === 'held' || P.mode === 'fly' ? P.angle : pose[1]
  const spins = P.mode === 'fly' || (P.mode === 'react' && REACT[P.react].spins)
  const footY = groundY - P.y - pose[0] * H
  const key = `${idx}|${P.x | 0}|${footY | 0}|${angle.toFixed(2)}|${pose[2]}|${pose[3]}|${P.face}|${particles.length}|${row.f.length}|${P.gait}`
  if (!dirty && !particles.length && key === lastKey && !bubble) return
  lastKey = key; dirty = false

  ctx.setTransform(DPR, 0, 0, DPR, 0, 0)
  ctx.clearRect(0, 0, SW, SH)
  const lift = Math.min(1, (groundY - footY) / (SH * 0.5))
  ctx.fillStyle = 'rgba(40,30,20,.16)'
  ctx.beginPath()
  ctx.ellipse(P.x, groundY + 2, W * 0.32 * (1 - lift * 0.5), K * 1.6 * (1 - lift * 0.5), 0, 0, Math.PI * 2)
  ctx.fill()

  const fr = row.f[idx]
  ctx.imageSmoothingEnabled = rig.smooth
  if (rig.smooth) ctx.imageSmoothingQuality = 'high'
  ctx.save()
  ctx.translate(P.x, spins ? footY - H / 2 : footY)
  ctx.rotate(angle)
  ctx.scale(P.face * pose[2], pose[3])
  ctx.drawImage(fr.img, fr.sx, fr.sy, fr.sw, fr.sh, -W / 2, spins ? -H / 2 : -H, W, H)
  ctx.restore()
  if (P.mode === 'study') drawDesk(P.x + P.face * W * 0.18, groundY, H)

  for (let i = particles.length - 1; i >= 0; i--) {
    const p = particles[i], u = (t - p.t0) / p.d
    if (u >= 1) { particles.splice(i, 1); continue }
    ctx.globalAlpha = u < 0.2 ? u / 0.2 : u > 0.7 ? (1 - u) / 0.3 : 1
    ctx.fillStyle = p.color
    ctx.font = `800 ${p.size}px -apple-system, system-ui, sans-serif`
    ctx.textAlign = 'center'
    ctx.fillText(p.text, p.x, p.y + p.vy * u)
  }
  ctx.globalAlpha = 1

  if (bubble) {
    if (t > bubble.until) { bubble = null; bubbleEl.hidden = true }
    else {
      const bw = bubbleEl.offsetWidth, left = Math.max(bw / 2 + 8, Math.min(SW - bw / 2 - 8, P.x))
      bubbleEl.style.transform = `translate(${left - bw / 2}px, ${Math.max(8, footY - H - 14 - bubbleEl.offsetHeight)}px)`
      bubbleEl.style.setProperty('--tail', `${Math.max(16, Math.min(bw - 16, bw / 2 + P.x - left))}px`)
    }
  }
}

// Touch: tap = reaction (ClickCombo), hold = petting, drag and fling = thrown (CursorBuddy), tap the grass = walk there.
const ptr = { id: null, x0: 0, y0: 0, t0: 0, onChar: false, moved: false, timer: 0, samples: [] }
function hitChar(x, y) {
  const W = FW * K, H = FH * K, pad = 14, footY = groundY - P.y
  return x > P.x - W / 2 - pad && x < P.x + W / 2 + pad && y > footY - H - pad && y < footY + pad
}
function local(e) { const r = stage.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top] }
stage.addEventListener('pointerdown', e => {
  if (!rig || ptr.id !== null || e.target.closest('#focusPill')) return
  unlockAudio()
  const [x, y] = local(e)
  Object.assign(ptr, { id: e.pointerId, x0: x, y0: y, t0: performance.now(), onChar: hitChar(x, y), moved: false, samples: [[x, y, performance.now()]] })
  P.lastInput = performance.now()
  $('#hint').classList.add('gone'); store.set('hinted', true)
  stage.setPointerCapture(e.pointerId)
  if (ptr.onChar && P.mode !== 'study') {
    ptr.timer = setTimeout(() => {
      if (ptr.moved || ptr.id === null || P.mode === 'fly') return
      P.mode = 'pet'; P.react = null
      setGait('special', 60000, takeOf(current, 'special'))
      const own = P.take && current.say[P.take]
      say(own?.length ? pick('say.' + P.take, own) : dress(line('pet')), 3000)
      cry('normal'); vibrate(15)
      P.petNext = 0
    }, 450)
  }
})
stage.addEventListener('pointermove', e => {
  if (e.pointerId !== ptr.id) return
  const [x, y] = local(e), now = performance.now()
  ptr.samples.push([x, y, now])
  while (ptr.samples.length > 2 && now - ptr.samples[0][2] > 100) ptr.samples.shift()
  if (!ptr.moved && Math.hypot(x - ptr.x0, y - ptr.y0) > 10) {
    ptr.moved = true
    clearTimeout(ptr.timer)
    if (ptr.onChar && P.mode !== 'study') {
      P.mode = 'held'; P.react = null; P.target = null
      setGait('held', 60000)
      say(dress(line('fly')), 1500)
      cry('hop')
    }
  }
  if (P.mode === 'held') {
    const s = ptr.samples[0], dtp = Math.max(1, now - s[2])
    P.held = { x, y: Math.min(y, groundY - FH * K * 0.85), vx: (x - s[0]) / dtp * 1000 }
  }
})
function release(e) {
  if (e.pointerId !== ptr.id) return
  unlockAudio()   // touch: pointerup is the user activation that lets iOS start the sound, pointerdown is not
  clearTimeout(ptr.timer)
  const now = performance.now(), [x, y] = local(e)
  ptr.id = null
  if (P.mode === 'held') {
    const s = ptr.samples[0], dtp = Math.max(16, now - s[2])
    const vx = (x - s[0]) / dtp * 1000, vy = -(y - s[1]) / dtp * 1000, cap = 3200
    P.mode = 'fly'; P.vx = Math.max(-cap, Math.min(cap, vx)); P.vy = Math.max(-cap, Math.min(cap, vy)); P.impact = 0
    setGait('fly', 60000)
    return
  }
  if (P.mode === 'pet') { P.mode = 'idle'; startReaction('jump', now / 1000); return }
  if (ptr.moved || e.type !== 'pointerup' || P.mode === 'fly') return
  if (ptr.onChar) {
    if (P.mode === 'study') { say(line('study')); cry('normal'); return }
    startReaction(comboClick(now / 1000), now / 1000)
  } else if (P.mode === 'idle' && y > groundY - FH * K * 2) {
    walkTo(x, Math.abs(x - P.x) > SW * 0.4 ? 'run' : 'walk')
  }
}
stage.addEventListener('pointerup', release)
stage.addEventListener('pointercancel', release)
stage.addEventListener('lostpointercapture', release)   // a system sheet or confirm() can take the pointer with no up or cancel

async function setChar(id, greet = true) {
  const ch = findChar(id) || builtins[0]
  let r
  try { r = await loadRig(ch) } catch { if (ch !== builtins[0]) return setChar(builtins[0].id, greet); return }
  current = ch; rig = r
  store.set('char', ch.id)
  $('#charName').textContent = name(ch)
  document.title = `${name(ch)} · ${T('title')}`
  dirty = true
  if (greet) { P.mode = focus.end ? 'study' : 'idle'; startReaction('jump', performance.now() / 1000); say(dress(line('hello'))) }
  else setGait(focus.end ? 'study' : 'stand', 1200)
  if (focus.end) { P.mode = 'study'; setGait('study', 1e9) }
}

// MARK: sheets

let openSheet = null
function showSheet(id) {
  closeSheet()
  openSheet = $('#sheet-' + id)
  openSheet.hidden = false; $('#scrim').hidden = false
  openSheet.querySelector('.body').scrollTop = 0
  if (id === 'friends') renderGrid()
  if (id === 'play') renderBest()
  if (id === 'settings') renderSettings()
  openSheet.querySelector('[data-close]').focus()
}
function closeSheet() {
  if (!openSheet) return
  openSheet.hidden = true; $('#scrim').hidden = true; openSheet = null
}
document.querySelectorAll('[data-sheet]').forEach(b => b.addEventListener('click', () => { unlockAudio(); showSheet(b.dataset.sheet) }))
document.querySelectorAll('[data-close]').forEach(b => b.addEventListener('click', closeSheet))
$('#scrim').addEventListener('click', closeSheet)
$('#nameBtn').addEventListener('click', () => showSheet('friends'))
document.addEventListener('keydown', e => { if (e.key === 'Escape') { if (gameOn) endGame(true); else closeSheet() } })

// A tile's picture: drawn once per friend straight from the sheet (or the pack's first walk frame), then the same canvas
// goes back into the grid every time the sheet opens. No rig is decoded for it.
const thumbs = new Map()
function thumb(ch) {
  if (thumbs.has(ch.id)) return thumbs.get(ch.id)
  const c = document.createElement('canvas'); c.width = FW * 5; c.height = FH * 5
  thumbs.set(ch.id, c)
  ;(async () => {
    const fr = ch.sheet ? { img: await loadImage('sprites/' + ch.sheet), sx: 0, sy: ch.rows.walk.y * FH, sw: FW, sh: FH }
      : await packFrame(ch.record.walk0, ch.smooth)
    const x = c.getContext('2d')
    x.imageSmoothingEnabled = !!ch.smooth
    x.drawImage(fr.img, fr.sx, fr.sy, fr.sw, fr.sh, 0, 0, c.width, c.height)
  })().catch(() => { thumbs.delete(ch.id) })   // a tile without a picture still picks; try again next time
  return c
}
function renderGrid() {
  const grid = $('#grid')
  grid.textContent = ''
  const groups = [['mine', packs], ['dogs', builtins.filter(c => c.kind === 'dog')], ['cats', builtins.filter(c => c.kind === 'cat')],
                  ['originals', builtins.filter(c => c.kind === 'original')]]
  for (const [title, list] of groups) {
    if (!list.length) continue
    const h = document.createElement('h3'); h.textContent = T(title)
    const tiles = document.createElement('div'); tiles.className = 'tiles'
    for (const ch of list) {
      const b = document.createElement('button')
      b.type = 'button'; b.className = 'tile'; b.setAttribute('aria-pressed', String(ch.id === current?.id))
      const s = document.createElement('span'); s.textContent = name(ch)
      b.append(thumb(ch), s)
      b.addEventListener('click', () => { closeSheet(); setChar(ch.id) })
      tiles.append(b)
    }
    grid.append(h, tiles)
  }
}

// MARK: import (.charamonitor)

const IS_IOS = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)
if (IS_IOS) $('#fileIn').removeAttribute('accept')   // iOS greys out a type it does not know
let toastTimer = 0
function toast(text, kind = '') {
  const t = $('#toast')
  t.textContent = text; t.className = 'toast ' + kind; t.hidden = false
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => { t.hidden = true }, 4200)
}
$('#fileIn').addEventListener('change', async e => {
  const f = e.target.files[0]
  e.target.value = ''
  if (!f) return
  if (f.size > CMSetup.LIMITS.bytes) return toast(T('tooBig'), 'bad')
  let buf
  try { buf = await f.arrayBuffer() } catch { return toast(T('unreadable'), 'bad') }   // an iCloud file still downloading
  importBytes(new Uint8Array(buf))
})
async function importBytes(u8) {
  toast(T('importing'))
  await new Promise(r => setTimeout(r, 40))
  let res
  try { res = CMSetup.readSetup(u8) } catch (e) { return toast(T(e.code || 'bad'), 'bad') }
  const skipped = res.skipped.length ? ' ' + T('importSkipped', res.skipped.length) : ''
  if (!res.packs.length) return toast(T('importedNone') + skipped, 'bad')
  const recs = res.packs.map(({ frames, ...p }) => ({ ...p, counts: Object.fromEntries(Object.entries(frames).map(([k, l]) => [k, l.length])),
    walk0: frames.walk[0].buffer, frames: Object.fromEntries(Object.entries(frames).map(([k, l]) => [k, l.map(u => u.buffer)])) }))
  try {
    await kv('readwrite', st => { recs.forEach(({ frames, ...meta }) => { st.put(frames, 'frames:' + meta.id); st.put(meta, 'pack:' + meta.id) }) })
  } catch { return toast(T('noStore'), 'bad') }
  recs.forEach(r => { rigs.delete(r.id); thumbs.delete(r.id) })
  await loadPacks()
  const c = res.chosen
  let chosen = null
  if (c.character === 'original' && c.originalID) {
    const hd = c.originalID.endsWith('-hd') ? c.originalID : c.originalID + '-hd'
    chosen = (c.style === 'illustration' && findChar(hd)) || findChar(c.originalID)
  } else if (c.character === 'cat' && c.catID) chosen = findChar(c.catID)
  else if (c.character === 'dog' && c.dogName) chosen = builtins.find(b => b.kind === 'dog' && (b.name.ko === c.dogName || b.name.en === c.dogName))
  closeSheet()
  await setChar((chosen || findChar(recs[0].id)).id)
  toast(T('imported', recs.length) + skipped)
}
async function takeInbox() {
  if (location.hash !== '#import') return
  history.replaceState(null, '', location.pathname)
  let buf
  try {
    buf = await kv('readonly', st => st.get('inbox'))
    await kv('readwrite', st => { st.delete('inbox') })
  } catch { return }
  if (buf) importBytes(new Uint8Array(buf))
}

// MARK: settings

function renderSettings() {
  $('#optSound').checked = prefs.sound
  $('#optVibe').checked = prefs.vibe
  $('#optLang').value = prefs.lang
  $('#vibeRow').hidden = !navigator.vibrate
  $('#delPacks').hidden = !packs.length
}
function setSound(on) {
  prefs.sound = on; store.set('sound', on)
  $('#soundBtn').setAttribute('aria-pressed', String(on))
  $('#soundBtn').setAttribute('aria-label', T(on ? 'soundOn' : 'soundOff'))
}
$('#soundBtn').addEventListener('click', () => { unlockAudio(); setSound(!prefs.sound); if (prefs.sound) cry('normal') })
$('#optSound').addEventListener('change', e => setSound(e.target.checked))
$('#optVibe').addEventListener('change', e => { prefs.vibe = e.target.checked; store.set('vibe', prefs.vibe); vibrate(20) })
$('#optLang').addEventListener('change', e => { prefs.lang = e.target.value; store.set('lang', prefs.lang); applyLang(); renderSettings() })
$('#delPacks').addEventListener('click', async () => {
  if (!confirm(T('deleteConfirm'))) return
  try { await kv('readwrite', st => { st.delete(PACK_KEYS()); st.delete(FRAME_KEYS()) }) } catch { /* nothing stored */ }
  packs.forEach(p => { rigs.delete(p.id); thumbs.delete(p.id) })
  packs = []
  if (current?.kind === 'pack') await setChar(builtins[0].id, false)
  renderSettings(); toast(T('deleted'))
})
$('#resetAll').addEventListener('click', () => {
  if (!confirm(T('resetConfirm'))) return
  try { Object.keys(localStorage).filter(k => k.startsWith('cm.')).forEach(k => localStorage.removeItem(k)) } catch { /* none */ }
  const r = indexedDB.deleteDatabase('charamonitor-web')
  r.onsuccess = r.onerror = r.onblocked = () => location.reload()
})

function applyLang() {
  const L = LANG()
  document.documentElement.lang = L
  document.querySelectorAll('[data-i18n]').forEach(el => { el.textContent = T(el.dataset.i18n) })
  document.querySelectorAll('[data-i18n-label]').forEach(el => el.setAttribute('aria-label', T(el.dataset.i18nLabel)))
  stage.setAttribute('aria-label', current ? name(current) : 'CharaMonitor')
  if (current) { $('#charName').textContent = name(current); document.title = `${name(current)} · ${T('title')}` }
  setSound(prefs.sound)
  renderBattery()
}

// MARK: battery (not on iOS Safari: the chip stays hidden there)

const battery = { level: null, charging: false }
function renderBattery() {
  const el = $('#battery')
  if (battery.level === null) { el.hidden = true; return }
  const pct = Math.round(battery.level * 100)
  el.hidden = false
  el.querySelector('b').style.width = `${Math.max(6, pct)}%`
  el.querySelector('span').textContent = battery.charging ? `${pct}% ${T('charging')}` : `${pct}%`
  el.className = 'chip battery' + (battery.charging ? ' charging' : pct < 20 ? ' low' : '')
}
if (navigator.getBattery) {
  navigator.getBattery().then(b => {
    const sync = () => { battery.level = b.level; battery.charging = b.charging; renderBattery() }
    sync()
    b.addEventListener('levelchange', sync)
    b.addEventListener('chargingchange', () => { sync(); if (b.charging && P.mode === 'idle') playExtra('eat') })
  }).catch(() => {})
}

// MARK: focus timer (the end is a timestamp, so a sleeping tab catches up when it wakes)

const focus = { end: store.get('focusEnd', 0) }
function startFocus(min) {
  unlockAudio()
  focus.end = Date.now() + min * 60000
  store.set('focusEnd', focus.end)
  closeSheet(); $('#hint').classList.add('gone')   // the pill takes its place
  P.mode = 'study'; P.target = null; setGait('study', 1e9)
  say(dress(line('study')))
  tickFocus()
}
function stopFocus(done) {
  focus.end = 0; store.set('focusEnd', 0)
  $('#focusPill').hidden = true
  P.mode = 'idle'; setGait('stand', 1500)
  if (done) {
    chime(); vibrate([200, 100, 200, 100, 300])
    startReaction('hearts', performance.now() / 1000)
    say(dress(line('done')), 5000)
    for (let i = 0; i < 6; i++) setTimeout(heart, i * 140)
  }
}
function tickFocus() {
  if (!focus.end) return
  const left = focus.end - Date.now()
  if (left <= 0) return stopFocus(true)
  $('#focusPill').hidden = false
  const s = Math.ceil(left / 1000)
  $('#focusLeft').textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
  if (P.mode === 'study' && Math.random() < 1 / 240) say(dress(line('study')))
}
setInterval(tickFocus, 1000)
document.querySelectorAll('[data-focus]').forEach(b => b.addEventListener('click', () => startFocus(+b.dataset.focus)))
$('#focusStop').addEventListener('click', () => stopFocus(false))
document.addEventListener('visibilitychange', () => { if (!document.hidden) { lastT = 0; tickFocus(); dirty = true; if (ac) unlockAudio() } else pauseGame() })

// MARK: mini games

const gcv = $('#gcv'), gx = gcv.getContext('2d')
let gameOn = false, game = null, gW = 0, gH = 0, gLast = 0, gRaf = 0
const best = k => store.get('best.' + k, 0)
function renderBest() {
  $('#bestStar').textContent = best('star') ? T('best', best('star')) : ''
  $('#bestMole').textContent = best('mole') ? T('best', best('mole')) : ''
}
function sizeGame() {
  const r = gcv.getBoundingClientRect()
  gW = r.width; gH = r.height
  gcv.width = Math.round(gW * DPR); gcv.height = Math.round(gH * DPR)
  game?.layout?.()
}
document.querySelectorAll('[data-game]').forEach(b => b.addEventListener('click', () => startGame(b.dataset.game)))
function startGame(kind) {
  unlockAudio(); closeSheet()
  gameOn = true
  $('#game').hidden = false; $('#gResult').hidden = true
  $('#gPad').hidden = kind !== 'star'
  $('#gHelp').textContent = T(kind === 'star' ? 'starHelp' : 'moleHelp'); $('#gHelp').style.opacity = 1
  setTimeout(() => { $('#gHelp').style.opacity = 0 }, 3500)
  sizeGame()
  game = kind === 'star' ? starGame() : moleGame()
  game.kind = kind
  game.grass = getComputedStyle(document.documentElement).getPropertyValue('--ground2').trim() || '#C3D9A8'   // dark mode too
  game.end = performance.now() + game.seconds * 1000
  gLast = 0
  cancelAnimationFrame(gRaf)   // 다시 하기 reuses the running loop's slot: one loop, however many replays
  gRaf = requestAnimationFrame(gameLoop)
}
function pauseGame() { if (gameOn && game && !game.over) game.pausedAt = performance.now() }
function gameLoop(now) {
  if (!gameOn) return
  gRaf = requestAnimationFrame(gameLoop)
  if (document.hidden) return
  if (game.pausedAt) { game.end += now - game.pausedAt; game.pausedAt = 0; gLast = 0 }
  const dt = Math.min(0.04, (now - (gLast || now)) / 1000)
  gLast = now
  const left = Math.max(0, game.end - now)
  if (!game.over) {
    game.update(dt, now)
    $('#gScore').textContent = game.score
    $('#gTime').textContent = Math.ceil(left / 1000)
    if (left <= 0) finishGame()
  }
  gx.setTransform(DPR, 0, 0, DPR, 0, 0)
  gx.clearRect(0, 0, gW, gH)
  game.draw(now)
}
function finishGame() {
  game.over = true
  const k = game.kind, prev = best(k), s = game.score
  if (s > prev) store.set('best.' + k, s)
  $('#gResTitle').textContent = T(k === 'star' ? 'starResult' : 'moleResult', s)
  $('#gResBest').textContent = s > prev && s > 0 ? T('newBest') : T('bestWas', prev)
  $('#gResult').hidden = false
  if (s > prev && s > 0) { chime(); vibrate([80, 60, 80]) } else cry('hop')
}
function endGame() {
  cancelAnimationFrame(gRaf)
  gameOn = false; game = null
  $('#game').hidden = true
  lastT = 0; dirty = true
}
$('#gClose').addEventListener('click', endGame)
$('#gDone').addEventListener('click', endGame)
$('#gAgain').addEventListener('click', () => startGame(game.kind))
window.addEventListener('resize', () => { resize(); if (gameOn) sizeGame() })

function drawSprite(c, fr, x, footY, w, h, face = 1, smooth = rig.smooth) {
  c.imageSmoothingEnabled = smooth
  c.save(); c.translate(x, footY); c.scale(face, 1)
  c.drawImage(fr.img, fr.sx, fr.sy, fr.sw, fr.sh, -w / 2, -h, w, h)
  c.restore()
}
function starPath(c, x, y, r) {
  c.beginPath()
  for (let i = 0; i < 10; i++) {
    const a = -Math.PI / 2 + i * Math.PI / 5, rr = i % 2 ? r * 0.45 : r
    c.lineTo(x + Math.cos(a) * rr, y + Math.sin(a) * rr)
  }
  c.closePath()
}

// 별 줍기: hold the halves to run, jump from the jump button or the upper screen; one-way platforms.
function starGame() {
  const g = { seconds: 60, score: 0, x: 0, y: 0, vx: 0, vy: 0, face: 1, ground: true, stars: [], left: false, right: false, plats: [], k: 3, t0: performance.now() }
  g.layout = () => {
    g.k = Math.max(2, Math.min(4, Math.floor(gW / 120)))
    const floor = $('#gPad').getBoundingClientRect().top - gcv.getBoundingClientRect().top - 46   // over the pad and its jump button
    g.floor = floor
    const gap = Math.min(110, floor * 0.17)
    g.gap = gap
    g.plats = [
      { x: 0, y: floor, w: gW },
      { x: gW * 0.06, y: floor - gap, w: gW * 0.34 }, { x: gW * 0.6, y: floor - gap * 1.15, w: gW * 0.34 },
      { x: gW * 0.3, y: floor - gap * 2.1, w: gW * 0.4 },
      { x: gW * 0.04, y: floor - gap * 3.1, w: gW * 0.3 }, { x: gW * 0.66, y: floor - gap * 3.2, w: gW * 0.3 },
    ]
    if (!g.x) { g.x = gW / 2; g.y = floor }
    g.y = Math.min(g.y, floor)
  }
  g.layout()
  const G = 2400
  g.jump = () => {
    if (g.over || !g.ground) return
    g.vy = -Math.sqrt(2 * G * g.gap * 1.3); g.ground = false
    cry('hop')
  }
  const spawn = () => {
    const p = g.plats[1 + Math.floor(Math.random() * (g.plats.length - 1))] || g.plats[0]
    const usePlat = Math.random() < 0.8 ? p : g.plats[0]
    const gold = Math.random() < 0.12
    g.stars.push({ x: usePlat.x + rand(18, usePlat.w - 18), y: usePlat.y - rand(28, g.gap * 0.9), gold, born: performance.now() })
  }
  for (let i = 0; i < 3; i++) spawn()
  g.update = (dt, now) => {
    const W = FW * g.k, H = FH * g.k
    g.vx = ((g.right ? 1 : 0) - (g.left ? 1 : 0)) * Math.max(220, gW * 0.6)
    if (g.vx) g.face = Math.sign(g.vx)
    g.x = Math.max(W / 2, Math.min(gW - W / 2, g.x + g.vx * dt))
    g.vy += G * dt
    const ny = g.y + g.vy * dt
    g.ground = false
    if (g.vy >= 0) {
      for (const p of g.plats) {
        if (g.x + W * 0.25 > p.x && g.x - W * 0.25 < p.x + p.w && g.y <= p.y + 0.5 && ny >= p.y) { g.y = p.y; g.vy = 0; g.ground = true; break }
      }
    }
    if (!g.ground) g.y = ny
    if (g.y > g.floor) { g.y = g.floor; g.vy = 0; g.ground = true }
    for (let i = g.stars.length - 1; i >= 0; i--) {
      const s = g.stars[i]
      if (s.gold && now - s.born > 5000) { g.stars.splice(i, 1); continue }
      if (Math.hypot(s.x - g.x, s.y - (g.y - H / 2)) < Math.max(W, H) * 0.55) {
        g.stars.splice(i, 1); g.score += s.gold ? 3 : 1
        vibrate(10)
        if (ac && prefs.sound) cry(s.gold ? 'hop' : 'normal')
      }
    }
    while (g.stars.length < 3) spawn()
  }
  g.draw = now => {
    const W = FW * g.k, H = FH * g.k
    for (const p of g.plats) {
      if (p === g.plats[0]) { gx.fillStyle = g.grass; gx.fillRect(0, p.y, gW, gH - p.y); continue }
      gx.fillStyle = '#B98A62'; gx.fillRect(p.x, p.y, p.w, 14)
      gx.fillStyle = '#9CCB7A'; gx.fillRect(p.x, p.y - 2, p.w, 7)
    }
    for (const s of g.stars) {
      const r = (s.gold ? 15 : 11) * (1 + 0.08 * Math.sin(now / 160 + s.x))
      gx.fillStyle = s.gold ? '#F29D1F' : '#F5C842'
      starPath(gx, s.x, s.y + Math.sin(now / 300 + s.x) * 3, r); gx.fill()
    }
    const row = !g.ground ? rowFor(rig, 'run') : g.vx ? rowFor(rig, 'run') : rowFor(rig, 'stand')
    const idx = g.vx || !g.ground ? frameAt(now - g.t0, row) : 0
    drawSprite(gx, row.f[idx], g.x, g.y, W, H, g.face)
  }
  return g
}
function padHold(el, side) {
  const on = v => e => { if (!game || game.kind !== 'star') return; e.preventDefault(); game[side] = v; el.classList.toggle('on', v); if (v) el.setPointerCapture(e.pointerId) }
  el.addEventListener('pointerdown', on(true))
  el.addEventListener('pointerup', on(false)); el.addEventListener('pointercancel', on(false)); el.addEventListener('lostpointercapture', on(false))
}
padHold($('#gLeft'), 'left'); padHold($('#gRight'), 'right')
$('#gJump').addEventListener('pointerdown', e => { e.preventDefault(); game?.jump?.() })
gcv.addEventListener('pointerdown', e => {
  if (!game || game.over) return
  const r = gcv.getBoundingClientRect(), x = e.clientX - r.left, y = e.clientY - r.top
  if (game.kind === 'star') game.jump()
  else game.tap(x, y)
})
document.addEventListener('keydown', e => {
  if (!gameOn || !game || game.kind !== 'star') return
  if (e.key === 'ArrowLeft') game.left = true
  if (e.key === 'ArrowRight') game.right = true
  if (e.key === 'ArrowUp' || e.key === ' ') { e.preventDefault(); game.jump() }
})
document.addEventListener('keyup', e => {
  if (!game || game.kind !== 'star') return
  if (e.key === 'ArrowLeft') game.left = false
  if (e.key === 'ArrowRight') game.right = false
})

// 두더지잡기: the friend pops out of one of nine holes; tap it before it hides.
function moleGame() {
  const g = { seconds: 30, score: 0, holes: [], moles: [], next: 0, t0: performance.now() }
  g.layout = () => {
    const top = gH * 0.24, area = gH * 0.66, cols = 3, rows = 3
    const cw = gW / cols, rh = area / rows
    g.k = Math.max(2, Math.min(5, Math.floor(Math.min(cw * 0.8 / FW, rh * 0.62 / FH))))
    g.holes = []
    for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) g.holes.push({ x: cw * (c + 0.5), y: top + rh * (r + 0.78), rx: cw * 0.36 })
  }
  g.layout()
  g.update = (dt, now) => {
    const u = 1 - Math.max(0, g.end - now) / (g.seconds * 1000)
    if (now >= g.next) {
      const free = g.holes.map((_, i) => i).filter(i => !g.moles.some(m => m.hole === i))
      if (free.length) g.moles.push({ hole: free[Math.floor(Math.random() * free.length)], t0: now, d: 1150 - 500 * u, hit: 0 })
      g.next = now + rand(380, 820) * (1 - 0.4 * u)
    }
    g.moles = g.moles.filter(m => m.hit ? now - m.hit < 450 : now - m.t0 < m.d)
  }
  const height = (m, now) => {
    if (m.hit) return Math.max(0, 1 - (now - m.hit) / 300)
    const t = (now - m.t0) / m.d
    return t < 0.18 ? t / 0.18 : t > 0.82 ? (1 - t) / 0.18 : 1
  }
  g.tap = (x, y) => {
    const now = performance.now(), W = FW * g.k, H = FH * g.k
    for (const m of g.moles) {
      if (m.hit) continue
      const h = g.holes[m.hole], top = h.y - H * height(m, now)
      if (Math.abs(x - h.x) < W * 0.6 && y > top - 16 && y < h.y + 16 && height(m, now) > 0.3) {
        m.hit = now; g.score++
        cry('hop'); vibrate(15)
        return
      }
    }
  }
  g.draw = now => {
    const W = FW * g.k, H = FH * g.k
    gx.fillStyle = g.grass; gx.fillRect(0, gH * 0.2, gW, gH)
    for (const [i, h] of g.holes.entries()) {
      const ry = h.rx * 0.3
      gx.fillStyle = '#5A4334'; gx.beginPath(); gx.ellipse(h.x, h.y, h.rx, ry, 0, 0, Math.PI * 2); gx.fill()
      const m = g.moles.find(mm => mm.hole === i)
      if (m) {
        const lift = height(m, now)
        gx.save()
        gx.beginPath(); gx.rect(h.x - h.rx, h.y - H - 40, h.rx * 2, H + 40); gx.clip()
        const row = m.hit ? rowFor(rig, 'dizzy') : rowFor(rig, 'stand')
        const idx = m.hit ? frameAt(now - m.hit, row) : 0
        drawSprite(gx, row.f[idx], h.x, h.y + H * (1 - lift) + ry * 0.3, W, H, i % 2 ? -1 : 1)
        gx.restore()
        if (m.hit) { gx.fillStyle = '#F08C2E'; gx.font = `800 ${Math.max(18, g.k * 6)}px system-ui`; gx.textAlign = 'center'; gx.fillText('!', h.x, h.y - H - 6) }
      }
      gx.strokeStyle = '#8A6A52'; gx.lineWidth = 4
      gx.beginPath(); gx.ellipse(h.x, h.y, h.rx, ry, 0, 0, Math.PI); gx.stroke()
    }
  }
  return g
}

// MARK: install card (iOS Safari, not yet on the home screen)

const standalone = navigator.standalone || matchMedia('(display-mode: standalone)').matches
if (IS_IOS && !standalone && !store.get('installHidden', false)) $('#install').hidden = false
document.querySelector('[data-close-install]').addEventListener('click', () => { $('#install').hidden = true; store.set('installHidden', true); resize() })

// MARK: start

async function start() {
  applyLang()
  if (store.get('hinted', false)) $('#hint').classList.add('gone')
  resize()
  new ResizeObserver(resize).observe(stage)
  try { await loadBuiltins() } catch { toast(T('bad'), 'bad'); return }
  await loadPacks()
  P.lastInput = performance.now()
  await setChar(store.get('char', 'dog-jelly'), false)
  applyLang()
  requestAnimationFrame(loop)
  if (focus.end) { if (focus.end <= Date.now()) stopFocus(true); else { P.mode = 'study'; setGait('study', 1e9); tickFocus() } }
  takeInbox()
  window.addEventListener('hashchange', takeInbox)
  if ('serviceWorker' in navigator && location.protocol !== 'file:') navigator.serviceWorker.register('sw.js').catch(() => {})
}
start()
