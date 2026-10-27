import { Capacitor, registerPlugin } from '@capacitor/core';
import { decodeState, initialState, type State } from './domain';
interface StorePlugin {
  read(): Promise<{ value: string | null }>;
  write(options: { value: string }): Promise<void>;
}
const Store = registerPlugin<StorePlugin>('MurmurStore');
const key = 'murmur.mobile.v1';
let writes: Promise<void> = Promise.resolve();
export async function loadState(): Promise<State> {
  const value = Capacitor.isNativePlatform() ? (await Store.read()).value : localStorage.getItem(key);
  return value ? decodeState(value) : initialState();
}
export function persistState(state: State): Promise<void> {
  const value = JSON.stringify(state);
  // Order snapshots; native writers replace the private file atomically.
  // A failed write must not poison subsequent retry attempts.
  writes = writes.catch(() => {}).then(async () => {
    if (Capacitor.isNativePlatform()) await Store.write({ value });
    else localStorage.setItem(key, value);
  });
  return writes;
}
