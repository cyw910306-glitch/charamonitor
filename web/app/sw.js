// Offline for the web app: the shell and every built-in sprite sheet (listed by sprites/index.json) are cached on
// install. Every answer comes from the cache at once and is refreshed from the network behind it (stale while
// revalidate), so a deploy reaches home-screen users on their next launch without a VERSION bump. Bump VERSION only to
// drop everything cached (say, sprites that went away); the old caches go on activate.
const VERSION = 'cm-app-1'
const SHELL = ['./', 'index.html', 'app.css', 'app.js', 'setup.js', 'manifest.webmanifest',
  'icons/icon-180.png', 'icons/icon-192.png', 'icons/icon-512.png', 'sprites/index.json']

self.addEventListener('install', e => {
  e.waitUntil((async () => {
    const cache = await caches.open(VERSION)
    await cache.addAll(SHELL.map(u => new Request(u, { cache: 'reload' })))
    const index = await (await cache.match('sprites/index.json')).json()
    await cache.addAll(index.characters.map(c => new Request('sprites/' + c.sheet, { cache: 'reload' })))
    await self.skipWaiting()
  })())
})

self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    for (const k of await caches.keys()) if (k.startsWith('cm-app-') && k !== VERSION) await caches.delete(k)
    await self.clients.claim()
  })())
})

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url)
  if (e.request.method !== 'GET' || url.origin !== location.origin) return
  e.respondWith((async () => {
    const cache = await caches.open(VERSION)
    const hit = await cache.match(e.request, { ignoreSearch: true })
    const fresh = fetch(e.request).then(r => {
      if (r.ok && r.type === 'basic') return cache.put(e.request, r.clone()).then(() => r, () => r)
      return r
    })
    if (hit) { e.waitUntil(fresh.catch(() => {})); return hit }
    try { return await fresh } catch (err) {
      if (e.request.mode === 'navigate') return (await cache.match('index.html')) || Response.error()
      throw err
    }
  })())
})
