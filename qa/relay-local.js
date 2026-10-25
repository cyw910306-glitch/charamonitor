'use strict';
// A local 원격 모임 relay for qa/relay-e2e.sh: web/api/relay.js on plain node http over the in-memory store
// (no vercel dev, no Upstash). Prints "relay <port>", then one line per request.
// Usage: node qa/relay-local.js [port, default any free] [--qa-unlimited]
// --qa-unlimited lifts the day, address, minute and room ceilings (two QA copies on one address poll every few seconds).
const http = require('http');
const relay = require('../web/api/relay.js');
const memoryRedis = require('../tools/relay/memory-redis.js');

const args = process.argv.slice(2), big = args.includes('--qa-unlimited');
const handler = relay.make({ redis: memoryRedis(), ...(big ? { commandsDay: 1e9, ipDayCommands: 1e9, ipPerMin: 1e9, roomDayCommands: 1e9 } : {}) });
const server = http.createServer((req, res) => {
  if (!req.url.startsWith('/api/relay')) { res.statusCode = 404; return res.end(); }
  let body = '';
  req.on('data', (c) => { body += c; if (body.length > relay.limits.MAX_BODY * 2) req.destroy(); });
  req.on('end', () => {
    if (body) req.body = body;   // Vercel hands the function the body; relay.js parses and size-checks it
    res.on('finish', () => console.log(req.method, res.statusCode));
    handler(req, res);
  });
});
server.listen(Number(args.find((a) => /^\d+$/.test(a)) || 0), '127.0.0.1', () => console.log('relay ' + server.address().port));
