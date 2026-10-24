'use strict';
// For relay.test.js and qa/relay-local.js.

/** The Redis commands relay.js uses, in memory (no expiry). */
function memoryRedis() {
  const kv = new Map(), log = [];
  const z = (k) => { if (!kv.has(k)) kv.set(k, new Map()); return kv.get(k); };
  const l = (k) => { if (!kv.has(k)) kv.set(k, []); return kv.get(k); };
  const run = ([cmd, k, ...a]) => {
    switch (cmd) {
      case 'INCR': { const v = Number(kv.get(k) || 0) + 1; kv.set(k, String(v)); return v; }
      case 'INCRBY': { const v = Number(kv.get(k) || 0) + Number(a[0]); kv.set(k, String(v)); return v; }
      case 'GET': return kv.has(k) ? kv.get(k) : null;
      case 'EXPIRE': return 1;
      case 'ZADD': { const m = z(k); const fresh = !m.has(a[1]); m.set(a[1], Number(a[0])); return fresh ? 1 : 0; }
      case 'ZSCORE': { const m = z(k); return m.has(a[0]) ? String(m.get(a[0])) : null; }
      case 'ZCARD': return z(k).size;
      case 'ZREM': return z(k).delete(a[0]) ? 1 : 0;
      case 'ZREMRANGEBYSCORE': {
        const m = z(k), max = Number(a[1]); let n = 0;
        for (const [id, s] of m) if (s <= max) { m.delete(id); n++; }
        return n;
      }
      case 'RPUSH': { const x = l(k); x.push(a[0]); return x.length; }
      case 'LTRIM': { const x = l(k); const keep = x.slice(Number(a[0])); x.length = 0; x.push(...keep); return 'OK'; }
      case 'LRANGE': return l(k).slice();
      case 'HSET': { const m = z(k); const fresh = !m.has(a[0]); m.set(a[0], a[1]); return fresh ? 1 : 0; }
      case 'HGETALL': return kv.has(k) ? [...kv.get(k)].flat() : [];
      default: throw new Error('mock: ' + cmd);
    }
  };
  const redis = async (cmds) => { log.push(cmds); return cmds.map(run); };
  redis.kv = kv;
  redis.log = log;
  return redis;
}

module.exports = memoryRedis;
