// Self-check: opens web/my-setup.bin the way the page does. SETUP_CODE=... node decrypt-check.mjs <file> <original>
import { webcrypto as w } from 'node:crypto'
import { readFileSync } from 'node:fs'
const [file, original] = process.argv.slice(2)
const b = readFileSync(file), enc = new TextEncoder()
if (b.subarray(0, 6).toString() !== 'CMSET1') throw new Error('not a locked setup file')
const base = await w.subtle.importKey('raw', enc.encode(process.env.SETUP_CODE.normalize('NFC')), 'PBKDF2', false, ['deriveKey'])
const key = await w.subtle.deriveKey({ name: 'PBKDF2', salt: b.subarray(6, 22), iterations: 600000, hash: 'SHA-256' },
  base, { name: 'AES-GCM', length: 256 }, false, ['decrypt'])
const out = Buffer.from(await w.subtle.decrypt({ name: 'AES-GCM', iv: b.subarray(22, 34) }, key, b.subarray(34)))
console.log(out.equals(readFileSync(original)) ? 'OK: same as the original' : 'MISMATCH')
