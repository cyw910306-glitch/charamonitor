'use strict';
// node --test tools/relay/*.test.js   (web/api/relay.js against an in-memory Upstash)
const test = require('node:test');
const assert = require('node:assert');
const relay = require('../../web/api/relay.js');

const memoryRedis = require('./memory-redis.js');

function call(handler, { method = 'GET', url = '/api/relay', body, ip = '1.2.3.4', headers = {} }) {
  return new Promise((resolve) => {
    const res = {
      headers: {}, setHeader(k, v) { this.headers[k.toLowerCase()] = v; },
      end(s) { resolve({ status: this.statusCode, body: JSON.parse(s), headers: this.headers }); },
    };
    handler({ method, url, body, headers: { 'x-forwarded-for': ip, ...headers } }, res);
  });
}

const room = 'a'.repeat(64);
const member = (n) => n.toString(16).padStart(32, '0');   // the secret a client sends
const id = (n) => relay.memberId(member(n));                // the id the room sees
const data = Buffer.alloc(40, 7).toString('base64');
const get = (h, m, after = 0, ip) => call(h, { url: `/api/relay?after=${after}`, ip, headers: { 'x-room': room, 'x-member': m } });
const post = (h, m, d = data, ip, extra = {}) => call(h, { method: 'POST', body: { room, member: m, data: d, ...extra }, ip });

test('no store configured: 503', async () => {
  const r = await get(relay.make({ redis: null }), member(1));
  assert.strictEqual(r.status, 503);
});

test('post then poll: only events after the given seq, never stored in the clear', async () => {
  const redis = memoryRedis(), h = relay.make({ redis });
  assert.strictEqual((await post(h, member(1))).body.seq, 1);
  assert.strictEqual((await post(h, member(2))).body.seq, 2);
  const all = await get(h, member(3));
  assert.strictEqual(all.status, 200);
  assert.strictEqual(all.headers['cache-control'], 'no-store');
  assert.deepStrictEqual(all.body.events.map((e) => [e.s, e.m]), [[1, id(1)], [2, id(2)]]);
  assert.strictEqual(all.body.members, 3);
  assert.deepStrictEqual((await get(h, member(3), 1)).body.events.map((e) => e.s), [2]);
  // Keys carry the room id's hash, never the id itself.
  for (const k of redis.kv.keys()) assert.ok(!k.includes(room), k);
  // Nor the member secrets: only their derived ids are stored or shown.
  const dump = JSON.stringify([...redis.kv].map(([k, v]) => [k, v instanceof Map ? [...v.keys()] : v]));
  for (const n of [1, 2, 3]) assert.ok(!dump.includes(member(n)), 'secret ' + n);
});

test("leaving with someone else's id as the secret does not free their seat", async () => {
  const redis = memoryRedis(), h = relay.make({ redis });
  await get(h, member(1), 0, '10.0.0.1');
  await get(h, member(2), 0, '10.0.0.2');
  const seen = (await get(h, member(2), 0, '10.0.0.2')).body;
  assert.strictEqual(seen.members, 2);
  // Member 2 knows member 1's id only as the room shows it (an event's m) and tries to leave as it.
  await post(h, member(1), data, '10.0.0.1');
  const victim = (await get(h, member(2), 0, '10.0.0.2')).body.events[0].m;
  assert.strictEqual(victim, id(1));
  assert.strictEqual((await post(h, victim, data, '10.0.0.2', { leave: true })).status, 200);
  const zset = [...redis.kv].find(([k]) => k.startsWith('relay:m:'))[1];
  assert.ok(zset.has(id(1)), 'member 1 still seated');
  assert.ok(!zset.has(relay.memberId(victim)), 'the forger left only their own forged seat');
  assert.strictEqual((await post(h, member(1), data, '10.0.0.1', { leave: true })).status, 200);
  assert.ok(!zset.has(id(1)), 'the real owner can leave');
});

test('one IP past its daily bytes is refused; other IPs and the global day are untouched', async () => {
  let t = 0;
  const redis = memoryRedis(), h = relay.make({ redis, now: () => t });
  const big = Buffer.alloc(1500, 7).toString('base64');   // 2000 characters
  const fits = Math.floor(relay.limits.IP_DAY_BYTES / big.length);
  for (let i = 0; i < fits; i++) {
    t = i * 1_000;   // 60 a minute (under the per-minute limits), all in day 0
    assert.strictEqual((await post(h, member(1), big, '6.6.6.6')).status, 200, 'post ' + i);
  }
  t = fits * 1_000;
  const before = redis.log.flat().length;
  assert.strictEqual((await post(h, member(1), big, '6.6.6.6')).status, 429);
  assert.strictEqual(redis.log.flat().length - before, 7);   // refused on the first round trip
  const total = Number(redis.kv.get('relay:day:0'));
  assert.strictEqual((await post(h, member(2), big, '7.7.7.7')).status, 200);   // another IP is fine
  assert.strictEqual(Number(redis.kv.get('relay:day:0')), total + big.length);
  t = 86_400_000;
  assert.strictEqual((await post(h, member(1), big, '6.6.6.6')).status, 200);   // a new day
});

test('one room past its daily bytes is refused before the global cap', async () => {
  const redis = memoryRedis(), h = relay.make({ redis, now: () => 5_000 });
  const other = 'b'.repeat(64);
  await post(h, member(1));
  const rdKey = [...redis.kv.keys()].find((k) => k.startsWith('relay:rday:'));
  redis.kv.set(rdKey, String(relay.limits.ROOM_DAY_BYTES));
  const total = redis.kv.get('relay:day:0');
  assert.strictEqual((await post(h, member(1), data, '1.1.1.1')).status, 429);
  assert.strictEqual(redis.kv.get('relay:day:0'), total);   // the global day never saw it
  assert.strictEqual((await call(h, { method: 'POST', body: { room: other, member: member(1), data }, ip: '1.1.1.1' })).status, 200);
});

test('at most 12 members; a known one still gets in', async () => {
  assert.strictEqual(relay.limits.MAX_MEMBERS, 12);
  const h = relay.make({ redis: memoryRedis() });
  for (let i = 1; i <= 12; i++) assert.strictEqual((await get(h, member(i), 0, '10.0.0.' + i)).status, 200);
  assert.strictEqual((await get(h, member(13), 0, '10.0.1.1')).status, 403);
  assert.strictEqual((await post(h, member(13), data, '10.0.1.1')).status, 403);
  assert.strictEqual((await post(h, member(13), data, '10.0.1.1', { live: true })).status, 403);
  assert.strictEqual((await get(h, member(4), 0, '10.0.1.1')).status, 200);
});

test('members idle for 24 h free their seat', async () => {
  let t = 1_000_000_000_000;
  const h = relay.make({ redis: memoryRedis(), now: () => t });
  for (let i = 1; i <= 12; i++) await get(h, member(i), 0, '10.0.0.' + i);
  t += relay.limits.TTL * 1000 + 1;
  assert.strictEqual((await get(h, member(13))).status, 200);
});

test('live signals stay out of the event list, one per member, gone after LIVE_MS', async () => {
  let t = 1_000_000;
  const redis = memoryRedis(), h = relay.make({ redis, now: () => t });
  await post(h, member(1));
  const typing = Buffer.alloc(30, 9).toString('base64');
  for (let i = 0; i < 3; i++) assert.deepStrictEqual((await post(h, member(2), typing, '2.2.2.2', { live: true })).body, { live: true });
  t += 1500;
  const r = (await get(h, member(3), 0, '3.3.3.3')).body;
  assert.strictEqual(r.v, 2);
  assert.strictEqual(r.seq, 1);   // live posts take no seq
  assert.deepStrictEqual(r.events.map((e) => e.m), [id(1)]);
  assert.deepStrictEqual(r.live, [{ m: id(2), d: typing, a: 1500 }]);
  t += relay.limits.LIVE_MS;
  assert.deepStrictEqual((await get(h, member(3), 1, '3.3.3.3')).body.live, []);
  // They still count against the day's bytes.
  assert.ok(Number([...redis.kv].find(([k]) => k.startsWith('relay:rday:'))[1]) >= 40 + 3 * typing.length);
});

test('a poll with nothing new does not read the event list', async () => {
  const redis = memoryRedis(), h = relay.make({ redis });
  await post(h, member(1));
  const n = redis.log.length;
  assert.strictEqual((await get(h, member(2), 1)).body.events.length, 0);
  assert.ok(!redis.log.slice(n).flat().some((c) => c[0] === 'LRANGE'));
  assert.strictEqual((await get(h, member(2), 0)).body.events.length, 1);
});

test('a room that expired and started over sends its new events to an old seq', async () => {
  const h = relay.make({ redis: memoryRedis() });
  await post(h, member(1));
  const r = (await get(h, member(2), 40)).body;
  assert.strictEqual(r.seq, 1);
  assert.deepStrictEqual(r.events.map((e) => e.s), [1]);
});

test('a busy room is asked to wait, then refused; all rooms stop at DAY_REQ', async () => {
  const redis = memoryRedis(), h = relay.make({ redis, now: () => 5_000 });
  await get(h, member(1));
  const k = [...redis.kv.keys()].find((x) => x.startsWith('relay:rreq:'));
  assert.strictEqual((await get(h, member(1))).body.wait, undefined);
  redis.kv.set(k, String(relay.limits.ROOM_DAY_REQ_SLOW));
  assert.strictEqual((await get(h, member(1))).body.wait, relay.limits.WAIT_SLOW);
  redis.kv.set(k, String(relay.limits.ROOM_DAY_REQ));
  assert.strictEqual((await get(h, member(1))).status, 429);
  assert.strictEqual((await call(h, { headers: { 'x-room': 'c'.repeat(64), 'x-member': member(1) } })).status, 200);   // another room is fine
  redis.kv.set('relay:dreq:0', String(relay.limits.DAY_REQ));
  assert.strictEqual((await call(h, { headers: { 'x-room': 'c'.repeat(64), 'x-member': member(1) } })).status, 503);
  const before = redis.log.flat().length;   // past the ceiling a request stops in the first round trip
  assert.strictEqual((await call(h, { headers: { 'x-room': 'c'.repeat(64), 'x-member': member(1) } })).status, 503);
  assert.strictEqual(redis.log.flat().length - before, 5);
});

test('keeps only the last 50 events', async () => {
  let t = 0;
  const h = relay.make({ redis: memoryRedis(), now: () => (t += 61_000) });   // a new minute each call: no rate limit
  for (let i = 0; i < 60; i++) await post(h, member(1));
  const r = await get(h, member(1));
  assert.strictEqual(r.body.events.length, relay.limits.KEEP);
  assert.strictEqual(r.body.events[0].s, 11);
});

test('rate limits per IP and per room', async () => {
  const h = relay.make({ redis: memoryRedis(), now: () => 5_000 });
  let last;
  for (let i = 0; i <= relay.limits.IP_PER_MIN; i++) last = await get(h, member(1));
  assert.strictEqual(last.status, 429);
  assert.strictEqual((await get(h, member(1), 0, '9.9.9.9')).status, 200);   // another IP is fine

  const h2 = relay.make({ redis: memoryRedis(), now: () => 5_000 });
  for (let i = 0; i < relay.limits.ROOM_PER_MIN; i++) await get(h2, member(1 + (i % 12)), 0, 'ip' + i);
  assert.strictEqual((await get(h2, member(1), 0, 'fresh')).status, 429);
});

test('a 429 flood costs 5 commands a request, and an IPv6 /64 counts as one address', async () => {
  const redis = memoryRedis(), h = relay.make({ redis, now: () => 5_000 });
  for (let i = 0; i < relay.limits.IP_PER_MIN; i++) await get(h, member(1), 0, '2001:db8:1:2::' + i.toString(16));
  const before = redis.log.flat().length;
  assert.strictEqual((await get(h, member(1), 0, '2001:db8:1:2:ffff::9')).status, 429);
  assert.strictEqual(redis.log.flat().length - before, 5);
  assert.strictEqual((await get(h, member(1), 0, '2001:db8:1:3::1')).status, 200);   // another /64
  assert.strictEqual(relay.ipKey('2001:0db8:00ab:0001:aaaa::5'), relay.ipKey('2001:db8:ab:1::7'));
  assert.strictEqual(relay.ipKey('::ffff:10.0.0.1'), '10.0.0.1');
});

test('leaving frees the seat at once', async () => {
  const h = relay.make({ redis: memoryRedis() });
  for (let i = 1; i <= 12; i++) await get(h, member(i), 0, '10.0.0.' + i);
  assert.strictEqual((await get(h, member(13), 0, '10.0.1.1')).status, 403);
  assert.strictEqual((await post(h, member(3), data, '10.0.0.3', { leave: true })).status, 200);
  assert.strictEqual((await get(h, member(13), 0, '10.0.1.1')).status, 200);
});

test('all posts together store at most DAY_BYTES a day', async () => {
  const redis = memoryRedis(), h = relay.make({ redis, now: () => 5_000 });
  redis.kv.set('relay:day:0', String(relay.limits.DAY_BYTES - 10));
  assert.strictEqual((await post(h, member(1))).status, 503);
  assert.strictEqual((await get(h, member(1))).body.events.length, 0);
});

test('ids in the query are ignored: only headers count for a poll', async () => {
  const h = relay.make({ redis: memoryRedis() });
  assert.strictEqual((await call(h, { url: `/api/relay?room=${room}&member=${member(1)}` })).status, 400);
});

test('rejects bad ids, data and oversized bodies', async () => {
  const h = relay.make({ redis: memoryRedis() });
  const ids = (r, m) => ({ 'x-room': r, 'x-member': m });
  assert.strictEqual((await call(h, { headers: ids('xyz', member(1)) })).status, 400);
  assert.strictEqual((await call(h, { url: '/api/relay?after=-1', headers: ids(room, member(1)) })).status, 400);
  assert.strictEqual((await call(h, { headers: ids(room.toUpperCase(), member(1)) })).status, 400);
  assert.strictEqual((await post(h, member(1), 'not base64!!!!!!!!!')).status, 400);
  assert.strictEqual((await post(h, member(1), 'QUJD')).status, 400);   // too short to be a sealed box
  assert.strictEqual((await post(h, member(1), 'A'.repeat(relay.limits.MAX_DATA + 4))).status, 400);
  assert.strictEqual((await call(h, { method: 'POST', body: 'x'.repeat(5000) })).status, 413);
  assert.strictEqual((await call(h, { method: 'POST', body: '{nope' })).status, 413);
  assert.strictEqual((await call(h, { method: 'POST', body: {}, headers: { 'content-length': '99999' } })).status, 413);
  assert.strictEqual((await call(h, { method: 'DELETE' })).status, 405);
  assert.strictEqual((await post(h, member(1))).status, 200);   // a string body as Vercel may pass it works too
  assert.strictEqual((await call(h, { method: 'POST', body: JSON.stringify({ room, member: member(1), data }) })).status, 200);
});

test('a store failure is 502, not a crash', async () => {
  const h = relay.make({ redis: async () => { throw new Error('down'); } });
  assert.strictEqual((await get(h, member(1))).status, 502);
});

test('upstash client posts the pipeline with the token', async () => {
  let seen;
  const fake = async (url, init) => { seen = { url, init }; return { ok: true, json: async () => [{ result: 1 }, { result: 'x' }] }; };
  const r = await relay.upstash('https://u.example/', 'tok', fake)([['INCR', 'a'], ['GET', 'b']]);
  assert.deepStrictEqual(r, [1, 'x']);
  assert.strictEqual(seen.url, 'https://u.example/pipeline');
  assert.strictEqual(seen.init.headers.Authorization, 'Bearer tok');
  await assert.rejects(relay.upstash('https://u', 't', async () => ({ ok: true, json: async () => [{ error: 'bad' }] }))([['X']]));
});

test('one IP past its daily requests is refused; other IPs still get in and the global day is not spent', async () => {
  let t = 0;
  const redis = memoryRedis(), h = relay.make({ redis, now: () => t });
  await get(h, member(1), 0, '6.6.6.6');
  const k = [...redis.kv.keys()].find((x) => x.startsWith('relay:ipreq:'));
  redis.kv.set(k, String(relay.limits.IP_DAY_REQ));
  const day = Number(redis.kv.get('relay:dreq:0') || 0);
  assert.strictEqual((await get(h, member(1), 0, '6.6.6.6')).status, 429);
  assert.strictEqual(Number(redis.kv.get('relay:dreq:0') || 0), day);   // a refused IP never touches everyone's day
  assert.strictEqual((await get(h, member(2), 0, '7.7.7.7')).status, 200);
  t = 86_400_000;
  assert.strictEqual((await get(h, member(1), 0, '6.6.6.6')).status, 200);   // a new day
});

