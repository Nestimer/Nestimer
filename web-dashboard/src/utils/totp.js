/**
 * TOTP-like code generation with 5-minute step.
 * Pure JS implementation (no Web Crypto API — works over plain HTTP).
 * Algorithm matches Python (api/app/totp.py) and Swift implementations.
 */

const STEP = 300 // 5 minutes

function hexToBytes(hex) {
  const bytes = new Uint8Array(hex.length / 2)
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(hex.substr(i * 2, 2), 16)
  }
  return bytes
}

// HMAC-SHA1 — pure JS implementation
function hmacSHA1(key, message) {
  const BLOCK_SIZE = 64
  // Pad or hash key to block size
  let k = new Uint8Array(BLOCK_SIZE)
  if (key.length > BLOCK_SIZE) {
    const hashed = sha1(key)
    k.set(hashed)
  } else {
    k.set(key)
  }

  const ipad = new Uint8Array(BLOCK_SIZE + message.length)
  const opad = new Uint8Array(BLOCK_SIZE + 20) // 20 = SHA1 digest size

  for (let i = 0; i < BLOCK_SIZE; i++) {
    ipad[i] = k[i] ^ 0x36
    opad[i] = k[i] ^ 0x5c
  }
  ipad.set(message, BLOCK_SIZE)

  const innerHash = sha1(ipad)
  opad.set(innerHash, BLOCK_SIZE)

  return sha1(opad)
}

// SHA-1 — pure JS implementation
function sha1(data) {
  let h0 = 0x67452301
  let h1 = 0xEFCDAB89
  let h2 = 0x98BADCFE
  let h3 = 0x10325476
  let h4 = 0xC3D2E1F0

  // Pre-processing: pad message
  const bitLen = data.length * 8
  const padded = new Uint8Array(Math.ceil((data.length + 9) / 64) * 64)
  padded.set(data)
  padded[data.length] = 0x80
  // Length in bits as big-endian 64-bit
  const view = new DataView(padded.buffer)
  view.setUint32(padded.length - 4, bitLen)

  const rotl = (n, s) => ((n << s) | (n >>> (32 - s))) >>> 0

  // Process each 64-byte block
  for (let offset = 0; offset < padded.length; offset += 64) {
    const w = new Uint32Array(80)
    for (let i = 0; i < 16; i++) {
      w[i] = view.getUint32(offset + i * 4)
    }
    for (let i = 16; i < 80; i++) {
      w[i] = rotl(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1)
    }

    let a = h0, b = h1, c = h2, d = h3, e = h4

    for (let i = 0; i < 80; i++) {
      let f, k
      if (i < 20) {
        f = ((b & c) | (~b & d)) >>> 0
        k = 0x5A827999
      } else if (i < 40) {
        f = (b ^ c ^ d) >>> 0
        k = 0x6ED9EBA1
      } else if (i < 60) {
        f = ((b & c) | (b & d) | (c & d)) >>> 0
        k = 0x8F1BBCDC
      } else {
        f = (b ^ c ^ d) >>> 0
        k = 0xCA62C1D6
      }

      const temp = (rotl(a, 5) + f + e + k + w[i]) >>> 0
      e = d
      d = c
      c = rotl(b, 30)
      b = a
      a = temp
    }

    h0 = (h0 + a) >>> 0
    h1 = (h1 + b) >>> 0
    h2 = (h2 + c) >>> 0
    h3 = (h3 + d) >>> 0
    h4 = (h4 + e) >>> 0
  }

  const result = new Uint8Array(20)
  const rv = new DataView(result.buffer)
  rv.setUint32(0, h0)
  rv.setUint32(4, h1)
  rv.setUint32(8, h2)
  rv.setUint32(12, h3)
  rv.setUint32(16, h4)
  return result
}

export function generateTOTP(secretHex, step = STEP) {
  const t = Math.floor(Date.now() / 1000 / step)

  // Encode counter as big-endian 8 bytes
  const msg = new Uint8Array(8)
  const view = new DataView(msg.buffer)
  view.setUint32(0, Math.floor(t / 0x100000000)) // high 32 bits
  view.setUint32(4, t >>> 0) // low 32 bits

  const key = hexToBytes(secretHex)
  const h = hmacSHA1(key, msg)

  const offset = h[19] & 0x0f
  const code = ((h[offset] & 0x7f) << 24 | h[offset + 1] << 16 | h[offset + 2] << 8 | h[offset + 3]) % 1000000
  return String(code).padStart(6, '0')
}

export function totpSecondsRemaining(step = STEP) {
  return step - (Math.floor(Date.now() / 1000) % step)
}
