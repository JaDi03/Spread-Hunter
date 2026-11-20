import { useSyncExternalStore } from 'react'
import { getState, subscribe } from './feed'

export function useFeed() {
  return useSyncExternalStore(subscribe, getState)
}
