// Locks a 내 설정 파일 for web/my-setup.html: PBKDF2-SHA256 (600k) + AES-256-GCM, the same WebCrypto opens it.
// Usage: SETUP_CODE=... node tools/setup-share/encrypt.mjs <in.charamonitor> web/my-setup.bin
// The code never goes in the repo; the output is git-ignored (personal packs inside).
import { pbkdf2Sync, randomBytes, createCipheriv } from 'node:crypto'
import { readFileSync, writeFileSync } from 'node:fs'

const [input, output] = process.argv.slice(2)
const code = process.env.SETUP_CODE
if (!input || !output || !code) { console.error('SETUP_CODE=... node encrypt.mjs <in> <out>'); process.exit(2) }
const salt = randomBytes(16), iv = randomBytes(12)
const key = pbkdf2Sync(code.normalize('NFC'), salt, 600000, 32, 'sha256')
const c = createCipheriv('aes-256-gcm', key, iv)
const body = Buffer.concat([c.update(readFileSync(input)), c.final(), c.getAuthTag()])
writeFileSync(output, Buffer.concat([Buffer.from('CMSET1'), salt, iv, body]))
console.log(`${output}: ${body.length} bytes`)
