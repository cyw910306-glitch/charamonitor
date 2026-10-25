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
  const seats = [...redis.kv].find(([k]) => k.startsWith('relay:r:'))[1];
  assert.ok(seats.has('m:' + id(1)), 'member 1 still seated');
  assert.ok(!seats.has('m:' + relay.memberId(victim)), 'the forger left only their own forged seat');
  assert.strictEqual((await post(h, member(1), data, '10.0.0.1', { leave: true })).status, 200);
  assert.ok(!seats.has('m:' + id(1)), 'the real owner can leave');
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
  // Each costs PREPAY.live at most.
  const { post: P, live: L, poll: G } = relay.limits.PREPAY;   // a first visit also marks the seat (+ its counts)
  assert.ok(redis.commands() <= 2 * P + 3 * L + 2 * G + 3 * 6, String(redis.commands()));
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

test('keeps only the last 50 events', async () => {
  let t = 0;
  const h = relay.make({ redis: memoryRedis(), now: () => (t += 61_000) });
  for (let i = 0; i < 60; i++) await post(h, member(1));
  const r = await get(h, member(1));
  assert.strictEqual(r.body.events.length, relay.limits.KEEP);
  assert.strictEqual(r.body.events[0].s, 11);
});

test('leaving frees the seat at once', async () => {
  const h = relay.make({ redis: memoryRedis() });
  for (let i = 1; i <= 12; i++) await get(h, member(i), 0, '10.0.0.' + i);
  assert.strictEqual((await get(h, member(13), 0, '10.0.1.1')).status, 403);
  assert.strictEqual((await post(h, member(3), data, '10.0.0.3', { leave: true })).status, 200);
  assert.strictEqual((await get(h, member(13), 0, '10.0.1.1')).status, 200);
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

const qday = (redis, day = 0) => redis.kv.get('relay:q:' + day);
const cmds = (redis, day = 0) => Number(qday(redis, day).get('cmd'));

test('every Upstash command is counted, pipelines item by item, the counting included', async () => {
  let t = 1_000;
  const redis = memoryRedis(), h = relay.make({ redis, now: () => t });
  await get(h, member(1), 0, '10.0.0.1');
  await post(h, member(1), data, '10.0.0.1');
  await post(h, member(2), data, '10.0.0.2', { live: true });
  await get(h, member(2), 0, '10.0.0.2');
  await get(h, member(2), 1, '10.0.0.2');
  t += relay.limits.SEEN_EVERY;
  await get(h, member(2), 1, '10.0.0.2');
  await post(h, member(1), data, '10.0.0.1', { leave: true });
  assert.strictEqual(cmds(redis), redis.commands());
  const perIP = [...qday(redis)].filter(([k]) => k.startsWith('ip:')).reduce((n, [, v]) => n + Number(v), 0);
  assert.strictEqual(perIP, redis.commands(), 'each address pays its extra commands too');
  // A refused request may have paid more than it ran, never less.
  for (let i = 13; i <= 30; i++) await get(h, member(i), 0, '10.1.0.' + i);
  assert.ok(cmds(redis) >= redis.commands());
});

test('a poll with nothing new is 5 commands; new events or a seat to mark cost a little more', async () => {
  let t = 1_000;
  const redis = memoryRedis(), h = relay.make({ redis, now: () => t });
  await post(h, member(1));
  await get(h, member(2), 1);
  const cost = async (after) => { const n = redis.commands(); const r = await get(h, member(2), after); return [redis.commands() - n, r.body.events.length]; };
  assert.strictEqual(relay.limits.PREPAY.poll, 5);
  assert.deepStrictEqual(await cost(1), [5, 0]);
  t += 60_000;
  assert.deepStrictEqual(await cost(1), [5, 0]);
  assert.deepStrictEqual(await cost(0), [9, 1]);   // + LRANGE and its counts (day, address and room)
  t += relay.limits.SEEN_EVERY;
  assert.deepStrictEqual(await cost(1), [10, 0]);   // + HSET, EXPIRE and their counts, once an hour
  const n = redis.commands();
  await post(h, member(2));
  assert.strictEqual(redis.commands() - n, relay.limits.PREPAY.post);
});

test('the day stops at COMMANDS_DAY: 503 quota with seconds to UTC midnight, then one request\'s commands, then none', async () => {
  const t = 86_400_000 * 3 + 3_600_000;   // 01:00 UTC
  const redis = memoryRedis(), h = relay.make({ redis, now: () => t });
  assert.strictEqual(relay.limits.COMMANDS_DAY, 5000);
  await post(h, member(1));
  qday(redis, 3).set('cmd', String(relay.limits.COMMANDS_DAY - 4));
  let r = await get(h, member(1));
  assert.strictEqual(r.status, 503);   // its 5 would pass the ceiling
  assert.deepStrictEqual(r.body, { error: 'quota', retry: 23 * 3600 });
  r = await post(h, member(1));
  assert.deepStrictEqual([r.status, r.body.error], [503, 'quota']);
  let n = redis.commands();
  assert.strictEqual((await get(h, member(1), 0, '9.9.9.9')).status, 503);
  assert.strictEqual(redis.commands() - n, 0);   // this instance knows: no command
  const cold = relay.make({ redis, now: () => t });   // another instance
  n = redis.commands();
  assert.strictEqual((await get(cold, member(1))).status, 503);
  assert.strictEqual(redis.commands() - n, relay.limits.PREPAY.poll);
  assert.deepStrictEqual(redis.log[redis.log.length - 1].map((c) => c[0]), ['HINCRBY', 'HGETALL']);
  // A new UTC day starts over, the same instance included.
  const next = relay.make({ redis, now: () => 86_400_000 * 4 });
  assert.strictEqual((await get(next, member(1))).status, 200);
});

test('one address gets about an eighth of the day; others still get in', async () => {
  const redis = memoryRedis(), h = relay.make({ redis, now: () => 5_000 });
  await get(h, member(1), 0, '6.6.6.6');
  const k = [...qday(redis).keys()].find((x) => x.startsWith('ip:'));
  qday(redis).set(k, String(relay.limits.IP_DAY_COMMANDS));
  const r = await get(h, member(1), 0, '6.6.6.6');
  assert.deepStrictEqual([r.status, r.body.error], [429, 'quota']);
  assert.ok(r.body.retry > 0);
  const n = redis.commands();
  assert.strictEqual((await get(h, member(1), 0, '6.6.6.6')).status, 429);
  assert.strictEqual(redis.commands() - n, 0);
  assert.strictEqual((await get(h, member(2), 0, '7.7.7.7')).status, 200);
});

test('past half the day rooms are asked to wait, longer past three quarters', async () => {
  const redis = memoryRedis(), h = relay.make({ redis, now: () => 5_000 });
  assert.strictEqual((await get(h, member(1))).body.wait, undefined);
  qday(redis).set('cmd', String(relay.limits.COMMANDS_DAY / 2));
  assert.strictEqual((await get(h, member(1))).body.wait, relay.limits.WAIT_SLOW);
  qday(redis).set('cmd', String(relay.limits.COMMANDS_DAY * 0.8));
  assert.strictEqual((await get(h, member(1))).body.wait, relay.limits.WAIT_SLOWER);
});

test('one address holds over an hour on screen at 25 s or 11 h of slow polls; it takes 5 to use up the day', () => {
  const { PREPAY, IP_DAY_COMMANDS, COMMANDS_DAY, ROOM_DAY_COMMANDS } = relay.limits;
  const seat = PREPAY.poll;   // marking the seat once an hour: + HSET, EXPIRE and their 3 counts
  assert.ok(1.3 * 3600 / 25 * PREPAY.poll + 2 * seat <= IP_DAY_COMMANDS);
  assert.ok(11 * 60 / 3.5 * PREPAY.poll + 11 * seat <= IP_DAY_COMMANDS);
  assert.ok(COMMANDS_DAY / IP_DAY_COMMANDS >= 5);
  assert.ok(ROOM_DAY_COMMANDS >= 2 * IP_DAY_COMMANDS && ROOM_DAY_COMMANDS < COMMANDS_DAY / 2);
  assert.ok(COMMANDS_DAY * 31 < 500_000 * 0.35);   // the free store is shared with another live site
});

test('a QA relay can raise the ceiling', async () => {
  const redis = memoryRedis(), h = relay.make({ redis, now: () => 5_000, commandsDay: 1e9, ipDayCommands: 1e9, ipPerMin: 1e9, roomDayCommands: 1e9 });
  await get(h, member(1));
  qday(redis).set('cmd', String(relay.limits.COMMANDS_DAY * 2));
  for (let i = 0; i < 30; i++) assert.strictEqual((await get(h, member(1))).status, 200);
});

test('one address with fresh seats every time still stops at IP_DAY_COMMANDS', async () => {
  let t = 5_000;
  const redis = memoryRedis(), h = relay.make({ redis, now: () => (t += 7_000) });   // under the minute's cap
  let i = 1;
  while ((await call(h, { url: '/api/relay?after=1', ip: '8.8.8.8', headers: { 'x-room': sha64(i), 'x-member': member(i) } })).status === 200) i++;
  assert.ok(redis.commands() <= relay.limits.IP_DAY_COMMANDS + 20, String(redis.commands()));
});
const sha64 = (n) => require('crypto').createHash('sha256').update(String(n)).digest('hex');

test('the day hash gets its expiry again after the first request, and events use a new list key', async () => {
  const redis = memoryRedis(), h = relay.make({ redis, now: () => 5_000 });
  for (let n = 0; n < 200; n++) await get(h, member(1), 0, '10.9.0.' + (n % 50));
  const expires = redis.log.flat().filter((c) => c[0] === 'EXPIRE' && c[1] === 'relay:q:0').length;
  assert.ok(expires >= 2, String(expires));
  redis.kv.set('relay:e:' + require('crypto').createHash('sha256').update('relay:' + room).digest('hex'), ['{"s":1,"m":"x","d":"old"}']);
  await post(h, member(1));
  assert.deepStrictEqual((await get(h, member(2))).body.events.map((e) => e.d), [data]);
});

const roomOf = (n) => sha64('room ' + n);
const getIn = (h, r, m, ip) => call(h, { url: '/api/relay?after=0', ip, headers: { 'x-room': r, 'x-member': m } });

test('a request the address refuses never raises the day', async () => {
  const redis = memoryRedis(), h = relay.make({ redis, now: () => 5_000 });
  await get(h, member(1), 0, '6.6.6.6');
  const k = [...qday(redis).keys()].find((x) => x.startsWith('ip:'));
  qday(redis).set(k, String(relay.limits.IP_DAY_COMMANDS));
  const before = cmds(redis);
  for (let i = 0; i < 20; i++) assert.strictEqual((await call(relay.make({ redis, now: () => 5_000 }),
    { url: '/api/relay?after=0', ip: '6.6.6.6', headers: { 'x-room': room, 'x-member': member(1) } })).status, 429);
  assert.strictEqual(cmds(redis), before, 'cold instances too');
  // The refused requests ran only the first round trip: no room read, no day count.
  assert.ok(redis.log.slice(-20).every((p) => p.every((c) => c[0] === 'HINCRBY' && c[2] !== 'cmd')));
});

test('a few addresses can not use up the day', async () => {
  let t = 5_000;
  const redis = memoryRedis(), h = relay.make({ redis, now: () => (t += 7_000) });
  const addresses = Math.floor(relay.limits.COMMANDS_DAY / relay.limits.IP_DAY_COMMANDS) - 1;
  for (let a = 0; a < addresses; a++) {
    let i = 0;   // each address in rooms of its own, so only its own cap stops it
    while ((await getIn(h, roomOf(a * 1000 + Math.floor(i / 100)), member(i + 1), '5.5.5.' + a)).status === 200) i++;
  }
  assert.ok(cmds(redis) < relay.limits.COMMANDS_DAY, String(cmds(redis)));
  assert.strictEqual((await get(h, member(1), 0, '4.4.4.4')).status, 200);
});

test('one address gets IP_PER_MIN requests a minute, then 429 slow until the next minute', async () => {
  let t = 60_000 * 10 + 15_000;
  const redis = memoryRedis(), h = relay.make({ redis, now: () => t });
  for (let i = 0; i < relay.limits.IP_PER_MIN; i++) assert.strictEqual((await get(h, member(1), 0, '3.3.3.3')).status, 200);
  const before = cmds(redis);
  const r = await get(h, member(1), 0, '3.3.3.3');
  assert.deepStrictEqual([r.status, r.body], [429, { error: 'slow', retry: 45 }]);
  const n = redis.commands();
  assert.strictEqual((await get(h, member(1), 0, '3.3.3.3')).status, 429);
  assert.strictEqual(redis.commands() - n, 0);   // this instance knows
  assert.strictEqual(cmds(redis), before);
  assert.strictEqual((await get(h, member(2), 0, '3.3.3.4')).status, 200);   // another address
  t += 45_000;
  assert.strictEqual((await get(h, member(1), 0, '3.3.3.3')).status, 200);
});

test('one room gets ROOM_DAY_COMMANDS, whoever polls it; other rooms still get in', async () => {
  let t = 5_000;
  const redis = memoryRedis(), h = relay.make({ redis, now: () => (t += 7_000) });
  let i = 0;   // 12 seats from 12 addresses, then fresh addresses to keep under each address's cap
  while ((await getIn(h, room, member(1 + (i % 12)), '10.7.' + Math.floor(i / 200) + '.' + (i % 12))).status === 200) i++;
  const r = await getIn(h, room, member(1), '10.8.0.1');
  assert.deepStrictEqual([r.status, r.body.error], [429, 'quota']);
  assert.ok(cmds(redis) <= relay.limits.ROOM_DAY_COMMANDS + 20, String(cmds(redis)));
  assert.strictEqual((await getIn(h, roomOf(1), member(1), '10.8.0.1')).status, 200);
});

test('IPv6 counts per /48; IPv4 and mapped IPv4 per address', () => {
  assert.strictEqual(relay.ipKey('2001:db8:abcd:12:1::7'), '2001:db8:abcd::/48');
  assert.strictEqual(relay.ipKey('2001:0DB8:abcd:ffff::1'), '2001:db8:abcd::/48');
  assert.strictEqual(relay.ipKey('2001:db8::1'), '2001:db8:0::/48');
  assert.strictEqual(relay.ipKey('fe80::1%en0'), 'fe80:0:0::/48');
  assert.strictEqual(relay.ipKey('::ffff:1.2.3.4'), '1.2.3.4');
  assert.strictEqual(relay.ipKey('1.2.3.4'), '1.2.3.4');
});

test('two IPv6 addresses in one /48 share the address cap', async () => {
  const redis = memoryRedis(), h = relay.make({ redis, now: () => 5_000 });
  await get(h, member(1), 0, '2001:db8:1:1::1');
  const k = [...qday(redis).keys()].find((x) => x.startsWith('ip:'));
  qday(redis).set(k, String(relay.limits.IP_DAY_COMMANDS));
  assert.strictEqual((await get(h, member(2), 0, '2001:db8:1:ff00::9')).status, 429);
  assert.strictEqual((await get(h, member(3), 0, '2001:db8:2::1')).status, 200);
});
