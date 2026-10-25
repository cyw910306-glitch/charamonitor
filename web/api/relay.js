'use strict';
// 원격 모임 relay: a slow mailbox per room for the app's end-to-end encrypted events. The server only ever sees a room id
// (derived from the room code on the Mac, hashed again here), a member id, opaque ciphertext and times.
// Storage: Upstash Redis REST (UPSTASH_REDIS_REST_URL / _TOKEN); without them every request is 503.
//
//   GET  /api/relay?after=<seq>  X-Room: <64 hex>  X-Member: <32 hex>
//        -> { v, seq, members, events: [{ s, m, d }], live: [{ m, d, a }], wait? }
//   POST /api/relay  { room, member, data: <base64, AES-GCM>, leave?: true, live?: true } -> { seq } (live: { live: true })
//
// live: true is a passing signal (입력 중): each member's last one is kept apart from the event list and shown LIVE_MS,
// with its age `a` in ms. `v` is this protocol (2: live). `wait` (seconds) asks the room to poll slower: the day's
// commands passed half (then 3/4) of COMMANDS_DAY.
//
// What the client sends as member is a random secret; the member id is the first 32 hex of its SHA-256 (memberId).
// Only that id is stored and shown to the room (events' m), so nobody can act, or leave, as someone else's seat.
// The ids ride in headers on GET so request logs (which keep the path) never hold them. At most 12 members seen in
// 24 h; a post with leave: true frees the seat. Everything expires 24 h after the room's last write.
//
// Free tier, never billed: the store is shared with other apps (keys under relay:), so every Upstash command this
// file runs (each item of a pipeline, the counting itself included) is counted, and all rooms together stop at
// COMMANDS_DAY a UTC day (about 72% of the free 500,000 a month): 503 { error: 'quota', retry: <s to UTC midnight> }.
// Each request pays its usual cost up front (PREPAY). The address and the room pay first, in the first round trip:
// one address gets at most IP_DAY_COMMANDS a day (429 quota) and IP_PER_MIN requests a minute (429 { error: 'slow',
// retry }), one room ROOM_DAY_COMMANDS (429 quota). Only a request both let through raises the day's count, so a
// refused flood spends its own address's (or room's) budget, never everyone's. Its few commands are outside the day's
// count but inside its address's, and the 28% left of the free month covers them. Once this instance has refused a
// day, address or room it answers again without a command.
// The ceiling also caps bytes: at most a few MB of posts a day, gone 24 h later.
// The room is one hash (s: seq, m:<id>: last seen, x:<id>: live) beside its event list, so a poll with nothing new is
// 5 commands: the address's day and minute and the room's day, then the day's count and the room (the minute and the
// room's day are 2 more than before, the price of those caps). The app polls every 20 to 30 s while a member's
// character or the room is on screen and someone else is there, else every 2 to 5 min.
// Capacity: one address is about 2 h on screen a day and one room two addresses' worth, so the day serves at least four
// rooms (the waits past half and 3/4 slow every room). Past an address's or a room's share only that one rests;
// past the day, all rooms rest.

const crypto = require('crypto');

const TTL = 86400;
const MAX_MEMBERS = 12;
const KEEP = 50;              // events per room
const MAX_BODY = 4096;        // bytes of request body
const MAX_DATA = 2048;        // characters of base64 ciphertext
const COMMANDS_DAY = 5000;    // all rooms, a UTC day: 155,000 in a 31-day month. The store is a free Upstash database
                              // (500,000 a month) shared with another live site, which keeps the larger part.
// One address (an IPv6 /48): 1,000 is 200 polls, about 80 min on screen at 25 s or 11 h of the 2 to 5 min polls, with
// little left for posts. A fifth of the day, so it takes five addresses to use it up.
const IP_DAY_COMMANDS = 1000;
const IP_PER_MIN = 10;        // requests: a poll every 20 s is 3, typing at most 2, plus lines; or two Macs at home
const ROOM_DAY_COMMANDS = 2000;   // two members' worth, under half the day, so one room can not use it all up
const PREPAY = { poll: 5, live: 6, post: 11 };   // a request's usual commands, the counting included
const SEEN_EVERY = 3600 * 1000;   // a poll marks its seat seen at most this often (seats free after 24 h unseen)
const LIVE_MS = 6000;
const WAIT_SLOW = 120;        // past half the day
const WAIT_SLOWER = 300;      // past three quarters

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

/** What the IP limits count: an IPv4 address, or an IPv6 /48 (a home or phone gets a /64 and often a /56 or /48, so a
 *  /64 key would let one client walk through thousands of fresh addresses). */
function ipKey(ip) {
  if (!ip.includes(':') || /^::ffff:\d/.test(ip)) return ip.replace(/^::ffff:/, '');
  const [head, tail = ''] = ip.split('%')[0].split('::');
  const h = head ? head.split(':') : [], t = tail ? tail.split(':') : [];
  const full = ip.includes('::') ? [...h, ...Array(Math.max(0, 8 - h.length - t.length)).fill('0'), ...t] : h;
  return full.slice(0, 3).map((x) => x.toLowerCase().replace(/^0+(?=.)/, '')).join(':') + '::/48';
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
function make({ redis, now = () => Date.now(), commandsDay = COMMANDS_DAY, ipDayCommands = IP_DAY_COMMANDS,
  ipPerMin = IP_PER_MIN, roomDayCommands = ROOM_DAY_COMMANDS }) {
  // Days (and day:address, day:room, minute:address) this instance has already refused: answered again without a command.
  const shut = new Set();
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

    const t = now(), day = Math.floor(t / 86400000), minute = Math.floor(t / 60000), h = sha('relay:' + room);
    const ipH = sha(ipKey(clientIP(req))).slice(0, 24), roomH = h.slice(0, 24);
    const retry = Math.max(1, Math.ceil(((day + 1) * 86400000 - t) / 1000));
    const quota = (code) => send(res, code, { error: 'quota', retry });
    const slow = () => send(res, 429, { error: 'slow', retry: Math.max(1, Math.ceil(((minute + 1) * 60000 - t) / 1000)) });
    if (shut.has(String(day))) return quota(503);
    if (shut.has(day + ':' + ipH) || shut.has(day + ':r:' + roomH)) return quota(429);
    if (shut.has(minute + ':m:' + ipH)) return slow();
    if (shut.size > 10000) shut.clear();
    const kDay = 'relay:q:' + day, kRoom = 'relay:r:' + h, kEvents = 'relay:ev:' + h;   // not relay:e: (the old relay's list, seq from relay:n:)
    const fIP = 'ip:' + ipH, fRoom = 'r:' + roomH;
    const isPost = req.method === 'POST';

    // Every command is counted on the address and the room in the first round trip, and in kDay's cmd in the second
    // (both pay PREPAY); a later one that goes past what was paid adds its own HINCRBYs for the rest.
    let paid = PREPAY[!isPost ? 'poll' : live ? 'live' : 'post'], used = 0;
    const run = (cmds) => {
      used += cmds.length;
      if (used > paid) {   // the address and the room pay the rest too, so their caps hold
        const extra = String(used + 3 - paid);
        cmds.push(['HINCRBY', kDay, 'cmd', extra], ['HINCRBY', kDay, fIP, extra], ['HINCRBY', kDay, fRoom, extra]);
        used += 3; paid = used;
      }
      return redis(cmds);
    };

    try {
      // The address and the room first: a request refused here never touches the day's count.
      const [ipUsed, perMin, roomUsed] = await run([['HINCRBY', kDay, fIP, String(paid)],
        ['HINCRBY', kDay, 'n:' + minute + ':' + ipH, '1'], ['HINCRBY', kDay, fRoom, String(paid)]]);
      if (ipUsed > ipDayCommands) { shut.add(day + ':' + ipH); return quota(429); }
      if (roomUsed > roomDayCommands) { shut.add(day + ':r:' + roomH); return quota(429); }
      if (perMin > ipPerMin) { shut.add(minute + ':m:' + ipH); return slow(); }
      const [total, flat] = await run([['HINCRBY', kDay, 'cmd', String(paid)], ['HGETALL', kRoom],
        // Each address's first request of the day, then one every 500 of its commands: kDay (made by the round trip
        // above) never stays without expiry.
        ...(ipUsed === paid || Math.floor(ipUsed / 500) !== Math.floor((ipUsed - paid) / 500) ? [['EXPIRE', kDay, 2 * TTL]] : [])]);
      if (total > commandsDay) { shut.add(String(day)); return quota(503); }

      const r = {};
      for (let i = 0; i + 1 < (flat || []).length; i += 2) r[flat[i]] = flat[i + 1];
      const stale = [], liveNow = [];
      let count = 0;
      for (const [k, v] of Object.entries(r)) {
        if (k.startsWith('m:')) {
          if (t - Number(v) < TTL * 1000) count++; else stale.push(k);
        } else if (k.startsWith('x:')) {
          let x;
          try { x = JSON.parse(v); } catch { x = null; }
          if (!x || typeof x.d !== 'string' || t - x.t >= SEEN_EVERY) { stale.push(k); continue; }
          if (t - x.t >= 0 && t - x.t < LIVE_MS) liveNow.push({ m: k.slice(2), d: x.d, a: t - x.t });
        }
      }
      const seen = r['m:' + member], known = seen != null && t - Number(seen) < TTL * 1000;
      if (!known && count >= MAX_MEMBERS) return send(res, 403, { error: 'full' });
      const tidy = stale.length ? [['HDEL', kRoom, ...stale]] : [];
      const seat = [['HSET', kRoom, 'm:' + member, String(t)], ['EXPIRE', kRoom, TTL], ...tidy];
      const seatDue = !known || t - Number(seen) >= SEEN_EVERY;

      if (live) {
        await run([...(seatDue ? seat : []), ['HSET', kRoom, 'x:' + member, JSON.stringify({ d: data, t })]]);
        return send(res, 200, { live: true });
      }
      if (isPost) {
        const [seq] = await run([['HINCRBY', kRoom, 's', '1']]);
        await run([
          ['RPUSH', kEvents, JSON.stringify({ s: seq, m: member, d: data })],
          ['LTRIM', kEvents, String(-KEEP), '-1'], ['EXPIRE', kEvents, TTL],
          ...(leave ? [['HDEL', kRoom, 'm:' + member, 'x:' + member], ['EXPIRE', kRoom, TTL], ...tidy] : seat),
        ]);
        return send(res, 200, { seq });
      }

      // Nothing new (the usual poll): the event list is not read at all.
      const seq = Number(r.s || 0), fresh = seq !== after;
      const later = [...(fresh ? [['LRANGE', kEvents, '0', '-1']] : []), ...(seatDue ? seat : [])];
      const [list] = later.length ? await run(later) : [];
      const events = (fresh ? list || [] : []).map((x) => { try { return JSON.parse(x); } catch { return null; } })
        .filter((e) => e && e.s > (seq < after ? 0 : after));   // a seq below after: the room expired and started over
      const body = { v: 2, seq, members: count + (known ? 0 : 1), events, live: liveNow };
      if (total > commandsDay * 0.75) body.wait = WAIT_SLOWER; else if (total > commandsDay / 2) body.wait = WAIT_SLOW;
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
module.exports.limits = { TTL, MAX_MEMBERS, KEEP, MAX_BODY, MAX_DATA, COMMANDS_DAY, IP_DAY_COMMANDS, IP_PER_MIN, ROOM_DAY_COMMANDS, PREPAY, SEEN_EVERY, LIVE_MS,
  WAIT_SLOW, WAIT_SLOWER };
