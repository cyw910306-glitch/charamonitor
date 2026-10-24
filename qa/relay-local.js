'use strict';
// A local 원격 모임 relay for qa/relay-e2e.sh: web/api/relay.js on plain node http over the in-memory store
// (no vercel dev, no Upstash). Prints "relay <port>", then one line per request.
// Usage: node qa/relay-local.js [port, default any free]
const http = require('http');
const relay = require('../web/api/relay.js');
const memoryRedis = require('../tools/relay/memory-redis.js');

const handler = relay.make({ redis: memoryRedis() });
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
server.listen(Number(process.argv[2] || 0), '127.0.0.1', () => console.log('relay ' + server.address().port));
