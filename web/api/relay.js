'use strict';
// 원격 모임 relay: a mailbox per room for the app's end-to-end encrypted events. The server only ever sees a room id
// (derived from the room code on the Mac, hashed again here), a member id, opaque ciphertext and times.
// Storage: Upstash Redis REST (UPSTASH_REDIS_REST_URL / _TOKEN); without them every request is 503.
//
//   GET  /api/relay?after=<seq>  X-Room: <64 hex>  X-Member: <32 hex>
//        -> { v, seq, members, events: [{ s, m, d }], live: [{ m, d, a }], wait? }
//   POST /api/relay  { room, member, data: <base64, AES-GCM>, leave?: true, live?: true } -> { seq } (live: { live: true })
//
// live: true is a passing signal (입력 중): each member's last one is kept LIVE_MS, outside the event list, so it never
// pushes chat out of the last KEEP; a poll gets it with its age `a` in ms. `v` is this protocol (2: live), so the app
// sends live only to a relay that keeps it apart. `wait` (seconds) asks the room to poll slower: the room's requests
// today passed ROOM_DAY_REQ_SLOW.
//
// What the client sends as member is a random secret; the member id is the first 32 hex of its SHA-256 (memberId).
// Only that id is stored and shown to the room (events' m), so nobody can act, or leave, as someone else's seat.
//
// The ids ride in headers on GET so request logs (which keep the path) never hold them. Both count the member in the
// room (at most 12 in 24 h); a post with leave: true frees the seat. Everything expires 24 h after the room's last write.
// Cost caps: the IP limit is its own first round trip, so a flood answered 429 costs 5 commands (7 for a post: its
// daily bytes ride along). Posts store at most IP_DAY_BYTES a day per IP and ROOM_DAY_BYTES per room, checked before
// the global DAY_BYTES, and each IP makes at most IP_DAY_REQ requests a day, so one client can not use up the day for everyone.
// Requests: the app polls every 3 to 5 s only while a room member's character or the room is on screen and someone
// else is there (30 to 60 s otherwise). A poll is about 16 commands, so a full room of 12 polling fast is about 180
// requests (2,900 commands) a minute; past ROOM_DAY_REQ_SLOW a day the room is told to wait WAIT_SLOW s, past
// ROOM_DAY_REQ it gets 429, and every room together stops at DAY_REQ (503), the store's daily ceiling.

const crypto = require('crypto');

const TTL = 86400;
const MAX_MEMBERS = 12;
const KEEP = 50;              // events per room
const MAX_BODY = 4096;        // bytes of request body
const MAX_DATA = 2048;        // characters of base64 ciphertext
const IP_PER_MIN = 90;          // two or three members behind one address polling every 3 s
const IP_DAY_REQ = 60000;       // two Macs behind one address polling fast all day; so a handful of addresses can not use up DAY_REQ
const ROOM_PER_MIN = 300;       // 12 members at 20 polls a minute, and their posts
const IP_DAY_BYTES = 4 * 1024 * 1024;     // about two thousand full-size posts a day
const ROOM_DAY_BYTES = 8 * 1024 * 1024;
const ROOM_DAY_REQ_SLOW = 40000;          // about 3.5 h of a full room polling fast; then WAIT_SLOW
const ROOM_DAY_REQ = 80000;               // slowed, a full room makes about 26,000 more a day: only a flood gets here
const DAY_REQ = 2000000;                  // about 32 million commands, all rooms together
const WAIT_SLOW = 45;
const LIVE_MS = 6000;
const DAY_BYTES = 48 * 1024 * 1024;   // with the 24 h TTL, at most about two days' worth stays in a 256 MB store

const ROOM_RE = /^[0-9a-f]{64}$/;
const MEMBER_RE = /^[0-9a-f]{32}$/;
const DATA_RE = /^[A-Za-z0-9+/]+={0,2}$/;

const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');
/** The member id the room sees, from the secret the client sends (RemoteMeet.swift MeetKeys.memberID). */
const memberId = (secret) => sha(secret).slice(0, 32);

/** Upstash REST pipeline: one round trip, the results in order (an item's error throws). */
function upstash(url, token, fetchImpl = fetch) {
  return async (cmds) => {
    const r = await fetchImpl(url.replace(/\/$/, '') + '/pipeline', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
      body: JSON.stringify(cmds),
    });
    if (!r.ok) throw new Error('upstash ' + r.status);
    const out = await r.json();
    return out.map((x) => { if (x.error) throw new Error(x.error); return x.result; });
  };
}

function send(res, code, body) {
  res.statusCode = code;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.end(JSON.stringify(body));
}

function clientIP(req) {
  const f = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim();
  return f || String(req.headers['x-real-ip'] || '') || (req.socket && req.socket.remoteAddress) || '?';
}

/** What the IP limit counts: an IPv4 address, or an IPv6 /64 (one home or phone gets a whole /64). */
function ipKey(ip) {
  if (!ip.includes(':') || /^::ffff:\d/.test(ip)) return ip.replace(/^::ffff:/, '');
  const [head, tail = ''] = ip.split('%')[0].split('::');
  const h = head ? head.split(':') : [], t = tail ? tail.split(':') : [];
  const full = ip.includes('::') ? [...h, ...Array(Math.max(0, 8 - h.length - t.length)).fill('0'), ...t] : h;
  return full.slice(0, 4).map((x) => x.toLowerCase().replace(/^0+(?=.)/, '')).join(':') + '::/64';
}

/** The request body as an object, or null when too big or not JSON. */
function readBody(req) {
  if (Number(req.headers['content-length'] || 0) > MAX_BODY) return null;
  let b = req.body;
  if (Buffer.isBuffer(b)) b = b.toString('utf8');
  if (typeof b === 'string') {
    if (Buffer.byteLength(b) > MAX_BODY) return null;
    try { b = JSON.parse(b); } catch { return null; }
  }
  if (!b || typeof b !== 'object' || Array.isArray(b)) return null;
  return JSON.stringify(b).length > MAX_BODY ? null : b;
}

/** The handler around `redis` (an Upstash-style pipeline function) and a clock in ms. */
function make({ redis, now = () => Date.now() }) {
  return async function handler(req, res) {
    if (!redis) return send(res, 503, { error: 'not configured' });
    if (req.method !== 'GET' && req.method !== 'POST') return send(res, 405, { error: 'method' });

    let room, member, data, leave = false, live = false, after = 0;
    if (req.method === 'GET') {
      const q = new URL(req.url, 'http://x').searchParams;
      room = req.headers['x-room']; member = req.headers['x-member'];
      const a = q.get('after') || '0';
      if (!/^[0-9]{1,12}$/.test(a)) return send(res, 400, { error: 'after' });
      after = Number(a);
    } else {
      const b = readBody(req);
      if (!b) return send(res, 413, { error: 'body' });
      ({ room, member, data } = b);
      leave = b.leave === true;
      live = b.live === true && !leave;
      if (typeof data !== 'string' || data.length < 16 || data.length > MAX_DATA || !DATA_RE.test(data)) {
        return send(res, 400, { error: 'data' });
      }
    }
    if (typeof room !== 'string' || !ROOM_RE.test(room) || typeof member !== 'string' || !MEMBER_RE.test(member)) {
      return send(res, 400, { error: 'room' });
    }

    member = memberId(member);

    const t = now(), minute = Math.floor(t / 60000), day = Math.floor(t / 86400000), h = sha('relay:' + room);
    const ipH = sha(ipKey(clientIP(req))).slice(0, 24);
    const kIP = 'relay:ip:' + ipH + ':' + minute, kRoom = 'relay:rl:' + h + ':' + minute;
    const kIPDay = 'relay:ipday:' + ipH + ':' + day, kIPReq = 'relay:ipreq:' + ipH + ':' + day, kRoomDay = 'relay:rday:' + h + ':' + day;
    const kMembers = 'relay:m:' + h, kEvents = 'relay:e:' + h, kSeq = 'relay:n:' + h, kLive = 'relay:x:' + h;
    const kDay = 'relay:day:' + day, kRoomReq = 'relay:rreq:' + h + ':' + day, kDayReq = 'relay:dreq:' + day;
    const isPost = req.method === 'POST';

    try {
      // A post's bytes count against its IP even when refused: only that IP pays for its flood.
      // DAY_REQ is read here too (counted below, so an IP's 429 flood never uses up everyone's day): past the
      // ceiling a request costs 3 commands, not 14.
      const [ipCount, , ipReq, , dayUsed, ipBytes] = await redis([['INCR', kIP], ['EXPIRE', kIP, 60],
        ['INCR', kIPReq], ['EXPIRE', kIPReq, 2 * TTL], ['GET', kDayReq],
        ...(isPost ? [['INCRBY', kIPDay, data.length], ['EXPIRE', kIPDay, 2 * TTL]] : [])]);
      if (ipCount > IP_PER_MIN || ipReq > IP_DAY_REQ || (isPost && ipBytes > IP_DAY_BYTES)) return send(res, 429, { error: 'slow down' });
      if (Number(dayUsed) >= DAY_REQ) return send(res, 503, { error: 'busy' });
      const [roomCount, , , known, count, roomReq, , dayReq, , last] = await redis([
        ['INCR', kRoom], ['EXPIRE', kRoom, 60],
        ['ZREMRANGEBYSCORE', kMembers, '-inf', String(t - TTL * 1000)],
        ['ZSCORE', kMembers, member], ['ZCARD', kMembers],
        ['INCR', kRoomReq], ['EXPIRE', kRoomReq, 2 * TTL], ['INCR', kDayReq], ['EXPIRE', kDayReq, 2 * TTL],
        isPost ? ['INCRBY', kRoomDay, data.length] : ['GET', kSeq],
        ...(isPost ? [['EXPIRE', kRoomDay, 2 * TTL]] : []),
      ]);
      if (roomCount > ROOM_PER_MIN || roomReq > ROOM_DAY_REQ || (isPost && last > ROOM_DAY_BYTES)) return send(res, 429, { error: 'slow down' });
      if (dayReq > DAY_REQ) return send(res, 503, { error: 'busy' });
      if (known == null && count >= MAX_MEMBERS) return send(res, 403, { error: 'full' });

      // ponytail: the cap check and the ZADD are two round trips, so two joins at once can make 13; a Lua script if it matters.
      if (isPost) {
        // The last safety net for the store's size: only posts every per-IP and per-room cap let through reach it.
        const [total] = await redis([['INCRBY', kDay, data.length], ['EXPIRE', kDay, 2 * TTL]]);
        if (total > DAY_BYTES) return send(res, 503, { error: 'busy' });
        if (live) {
          await redis([['ZADD', kMembers, String(t), member], ['EXPIRE', kMembers, TTL],
            ['HSET', kLive, member, JSON.stringify({ d: data, t })], ['EXPIRE', kLive, 60]]);
          return send(res, 200, { live: true });
        }
        const [seq] = await redis([['INCR', kSeq]]);
        await redis([
          leave ? ['ZREM', kMembers, member] : ['ZADD', kMembers, String(t), member],
          ['RPUSH', kEvents, JSON.stringify({ s: seq, m: member, d: data })],
          ['LTRIM', kEvents, String(-KEEP), '-1'],
          ['EXPIRE', kSeq, TTL], ['EXPIRE', kEvents, TTL], ['EXPIRE', kMembers, TTL],
        ]);
        return send(res, 200, { seq });
      }

      // Nothing new (the usual fast poll): the event list is not read at all.
      const seq = Number(last || 0), fresh = seq !== after;
      const [, , members, flat, list] = await redis([
        ['ZADD', kMembers, String(t), member], ['EXPIRE', kMembers, TTL], ['ZCARD', kMembers], ['HGETALL', kLive],
        ...(fresh ? [['LRANGE', kEvents, '0', '-1']] : []),
      ]);
      const events = (list || []).map((x) => { try { return JSON.parse(x); } catch { return null; } })
        .filter((e) => e && e.s > (seq < after ? 0 : after));   // a seq below after: the room expired and started over
      const liveNow = [];
      for (let i = 0; i + 1 < (flat || []).length; i += 2) {
        let x;
        try { x = JSON.parse(flat[i + 1]); } catch { continue; }
        if (x && typeof x.d === 'string' && t - x.t >= 0 && t - x.t < LIVE_MS) liveNow.push({ m: flat[i], d: x.d, a: t - x.t });
      }
      const body = { v: 2, seq, members, events, live: liveNow };
      if (roomReq > ROOM_DAY_REQ_SLOW) body.wait = WAIT_SLOW;
      return send(res, 200, body);
    } catch {
      return send(res, 502, { error: 'store' });
    }
  };
}

const env = process.env;
const handler = make({
  redis: env.UPSTASH_REDIS_REST_URL && env.UPSTASH_REDIS_REST_TOKEN
    ? upstash(env.UPSTASH_REDIS_REST_URL, env.UPSTASH_REDIS_REST_TOKEN) : null,
});
module.exports = handler;
module.exports.make = make;
module.exports.upstash = upstash;
module.exports.ipKey = ipKey;
module.exports.memberId = memberId;
module.exports.limits = { TTL, MAX_MEMBERS, KEEP, MAX_BODY, MAX_DATA, IP_PER_MIN, IP_DAY_REQ, ROOM_PER_MIN, IP_DAY_BYTES, ROOM_DAY_BYTES, DAY_BYTES,
  ROOM_DAY_REQ_SLOW, ROOM_DAY_REQ, DAY_REQ, WAIT_SLOW, LIVE_MS };
