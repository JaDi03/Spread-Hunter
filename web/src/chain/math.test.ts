import { describe, expect, it } from 'vitest'
import { feeFloor, formatUnits, isTxHash, spread, tokenPriceInUsdc } from './math'

// sqrt prices read from both demo pools on 2026-11-20
const BASE = 773516539332532763974439780233416446n
const UNI = 773129776350796264496690802441175302n

describe('tokenPriceInUsdc', () => {
  it('reads the demo pools at about 0.0105 USDC per HUNT', () => {
    const p = tokenPriceInUsdc(BASE, true, 6, 18)
    expect(p).toBeGreaterThan(0.0104)
    expect(p).toBeLessThan(0.0106)
  })

  it('inverts when USDC is currency1', () => {
    // same sqrt price read with the currencies swapped: the two prices multiply to scale squared
    const a = tokenPriceInUsdc(BASE, true, 6, 18)
    const b = tokenPriceInUsdc(BASE, false, 6, 18)
    expect(Math.abs((a * b) / 1e24 - 1)).toBeLessThan(1e-12)
  })

  it('rejects a zero price', () => {
    expect(tokenPriceInUsdc(0n, true, 6, 18)).toBeNaN()
  })
})

describe('spread', () => {
  it('matches the sqrt ratio squared', () => {
    const pa = tokenPriceInUsdc(BASE, true, 6, 18)
    const pb = tokenPriceInUsdc(UNI, true, 6, 18)
    const r = Number(BASE) / Number(UNI)
    expect(spread(pa, pb)).toBeCloseTo(r * r - 1, 12)
  })

  it('is symmetric', () => {
    expect(spread(1, 1.01)).toBeCloseTo(spread(1.01, 1), 15)
  })
})

describe('feeFloor', () => {
  it('is a little over 0.10% for two 0.05% pools', () => {
    const f = feeFloor(500, 500)
    expect(f).toBeGreaterThan(0.001)
    expect(f).toBeLessThan(0.00101)
  })
})

describe('formatUnits', () => {
  it('formats the README profit', () => {
    expect(formatUnits(472628n, 6, 6)).toBe('0.472628')
    expect(formatUnits(937402221914000000000n, 18, 4)).toBe('937.4022')
  })
})

describe('isTxHash', () => {
  it('accepts only 32-byte hex', () => {
    expect(isTxHash(`0x${'a'.repeat(64)}`)).toBe(true)
    expect(isTxHash(`0x${'a'.repeat(63)}`)).toBe(false)
    expect(isTxHash(`javascript:alert(1)`)).toBe(false)
    expect(isTxHash(`0x${'a'.repeat(64)}\n`)).toBe(false)
  })
})
