/**
 * TOTP-like code generation with 5-minute step.
 * Algorithm matches Python (api/app/totp.py) and Swift implementations.
 * Uses Web Crypto API (SubtleCrypto) for HMAC-SHA1.
 */

const STEP = 300 // 5 minutes

function hexToBytes(hex) {
  const bytes = new Uint8Array(hex.length / 2)
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(hex.substr(i * 2, 2), 16)
  }
  return bytes
}

export async function generateTOTP(secretHex, step = STEP) {
  const t = Math.floor(Date.now() / 1000 / step)

  // Encode counter as big-endian 8 bytes
  const msg = new ArrayBuffer(8)
  const view = new DataView(msg)
  view.setUint32(0, Math.floor(t / 0x100000000)) // high 32 bits
  view.setUint32(4, t >>> 0) // low 32 bits

  const key = hexToBytes(secretHex)
  const cryptoKey = await crypto.subtle.importKey(
    'raw', key, { name: 'HMAC', hash: 'SHA-1' }, false, ['sign']
  )
  const sig = await crypto.subtle.sign('HMAC', cryptoKey, msg)
  const h = new Uint8Array(sig)

  const offset = h[19] & 0x0f
  const code = ((h[offset] & 0x7f) << 24 | h[offset + 1] << 16 | h[offset + 2] << 8 | h[offset + 3]) % 1000000
  return String(code).padStart(6, '0')
}

export function totpSecondsRemaining(step = STEP) {
  return step - (Math.floor(Date.now() / 1000) % step)
}
