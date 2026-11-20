import { parseAbi } from 'viem'

export const reactiveAbi = parseAbi([
  'struct Side { uint160 sqrtPriceX96; uint128 liquidity; uint24 fee; bool priced; bool stocked; uint256 usdc; uint256 token; uint256 inventoryAt; uint256 priceAt; }',
  'struct Pool { uint256 chainId; address poolManager; bytes32 poolId; bool usdcIsCurrency0; uint24 fee; }',
  'struct Flight { bool active; bool legFailed; uint64 openUntil; uint256 nonce; bytes32[2] legs; bool[2] resolved; uint256[2] resolvedAt; }',
  'function sideState(uint256 side) view returns (Side)',
  'function flight() view returns (Flight)',
  'function pool(uint256 side) view returns (Pool)',
  'function paused() view returns (bool)',
  'function nonce() view returns (uint256)',
  'function failuresInARow() view returns (uint8)',
  'function cooldownUntil() view returns (uint256)',
  'event TradeRequested(uint256 indexed nonce, uint8 cheapSide, uint256 usdcIn, uint256 tokenAmount, uint256 expectedProfit, uint256 originTxHash, uint256 requestedAt)',
  'event TradeClosed(uint256 indexed nonce, bool timedOut, bool legFailed, uint256 closedAt)',
  'event AutoPaused(uint8 failuresInARow)',
])

export const stateViewAbi = parseAbi([
  'function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)',
])

export const poolManagerAbi = parseAbi([
  'event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)',
])

export const executorAbi = parseAbi([
  'event LegExecuted(bytes32 indexed legId, bool buyToken, uint256 paid, uint256 received)',
  'event LegFailed(bytes32 indexed legId, bytes reason)',
])
