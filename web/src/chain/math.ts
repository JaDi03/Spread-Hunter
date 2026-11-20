const Q96 = 2 ** 96

/** USDC paid for one whole token at the pool's sqrt price. */
export function tokenPriceInUsdc(
  sqrtPriceX96: bigint,
  usdcIsCurrency0: boolean,
  usdcDecimals: number,
  tokenDecimals: number,
): number {
  if (sqrtPriceX96 <= 0n) return Number.NaN
  const s = Number(sqrtPriceX96) / Q96
  // raw is currency1 base units per currency0 base unit
  const raw = s * s
  const scale = 10 ** (tokenDecimals - usdcDecimals)
  return usdcIsCurrency0 ? scale / raw : raw * scale
}

/** Relative gap of the dear price over the cheap one, as a fraction (0.001 = 0.10%). */
export function spread(priceA: number, priceB: number): number {
  if (!(priceA > 0) || !(priceB > 0)) return Number.NaN
  return Math.max(priceA, priceB) / Math.min(priceA, priceB) - 1
}

/** Uniswap fee units are hundredths of a basis point: 500 is 0.05%. */
export function feeFraction(fee: number): number {
  return fee / 1_000_000
}

/** Gap the two pool fees take from a round trip, the floor below which no trade pays. */
export function feeFloor(feeA: number, feeB: number): number {
  return 1 / ((1 - feeFraction(feeA)) * (1 - feeFraction(feeB))) - 1
}

export function formatUnits(value: bigint, decimals: number, shown: number): string {
  const neg = value < 0n
  const v = neg ? -value : value
  const base = 10n ** BigInt(decimals)
  const whole = v / base
  const frac = (v % base).toString().padStart(decimals, '0').slice(0, shown)
  const w = whole.toLocaleString('en-US')
  return `${neg ? '-' : ''}${w}${shown > 0 ? `.${frac}` : ''}`
}

const HASH_RE = /^0x[0-9a-fA-F]{64}$/

export function isTxHash(v: unknown): v is `0x${string}` {
  return typeof v === 'string' && HASH_RE.test(v)
}

export function shortHash(h: string): string {
  return `${h.slice(0, 6)}…${h.slice(-4)}`
}
