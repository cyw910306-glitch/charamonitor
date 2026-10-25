'use strict';
// For relay.test.js and qa/relay-local.js.

/** The Redis commands relay.js uses, in memory (no expiry). `log` keeps every pipeline as sent. */
function memoryRedis() {
  const kv = new Map(), log = [];
  const hash = (k) => { if (!kv.has(k)) kv.set(k, new Map()); return kv.get(k); };
  const l = (k) => { if (!kv.has(k)) kv.set(k, []); return kv.get(k); };
  const run = ([cmd, k, ...a]) => {
    switch (cmd) {
      case 'EXPIRE': return 1;
      case 'HINCRBY': { const m = hash(k); const v = Number(m.get(a[0]) || 0) + Number(a[1]); m.set(a[0], String(v)); return v; }
      case 'HSET': { const m = hash(k); const fresh = !m.has(a[0]); m.set(a[0], a[1]); return fresh ? 1 : 0; }
      case 'HDEL': { const m = hash(k); return a.filter((f) => m.delete(f)).length; }
      case 'HGETALL': return kv.has(k) ? [...kv.get(k)].flat() : [];
      case 'RPUSH': { const x = l(k); x.push(a[0]); return x.length; }
      case 'LTRIM': { const x = l(k); const keep = x.slice(Number(a[0])); x.length = 0; x.push(...keep); return 'OK'; }
      case 'LRANGE': return l(k).slice();
      default: throw new Error('mock: ' + cmd);
    }
  };
  const redis = async (cmds) => { log.push(cmds.map((c) => c.slice())); return cmds.map(run); };
  redis.kv = kv;
  redis.log = log;
  /** Commands run so far, every pipeline item counted. */
  redis.commands = () => log.reduce((n, p) => n + p.length, 0);
  return redis;
}

module.exports = memoryRedis;
