import { isTxHash, shortHash } from '../chain/math'
import { CHAINS, type ChainKey } from '../config/testnet'

export function TxLink({ chain, hash }: { chain: ChainKey; hash: string }) {
  if (!isTxHash(hash)) return <span className="tx-dim">n/a</span>
  return (
    <a className="tx" href={`${CHAINS[chain].explorer}/tx/${hash}`} target="_blank" rel="noopener noreferrer" title={`Open on ${CHAINS[chain].name} explorer`}>
      {shortHash(hash)} ↗
    </a>
  )
}
