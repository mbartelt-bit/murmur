import { beforeEach, describe, expect, it, vi } from 'vitest';
import { initialState } from './domain';
const bridge = vi.hoisted(() => ({ read: vi.fn(), write: vi.fn() }));
vi.mock('@capacitor/core', () => ({ Capacitor: { isNativePlatform: () => true }, registerPlugin: () => bridge }));
beforeEach(() => { vi.resetModules(); bridge.read.mockReset(); bridge.write.mockReset(); });
describe('native snapshot persistence', () => {
  it('orders writes so older drafts cannot overwrite newer edits', async () => {
    let release!: () => void;
    bridge.write.mockImplementationOnce(() => new Promise<void>(resolve => { release = resolve; })).mockResolvedValue(undefined);
    const { persistState } = await import('./storage');
    const first = initialState(); first.draft.text = 'First';
    const second = { ...first, draft: { ...first.draft, text: 'Second' } };
    const a = persistState(first); const b = persistState(second);
    await vi.waitFor(() => expect(bridge.write).toHaveBeenCalledTimes(1));
    release(); await Promise.all([a,b]);
    expect(JSON.parse(bridge.write.mock.calls[1][0].value).draft.text).toBe('Second');
  });
  it('allows recovery after a failed write', async () => {
    bridge.write.mockRejectedValueOnce(new Error('disk full')).mockResolvedValue(undefined);
    const { persistState } = await import('./storage');
    await expect(persistState(initialState())).rejects.toThrow('disk full');
    await expect(persistState(initialState())).resolves.toBeUndefined();
  });
  it('does not overwrite corrupt data or silently discard read failures', async () => {
    bridge.read.mockResolvedValueOnce({ value: '{"broken":true}' }).mockRejectedValueOnce(new Error('read failure'));
    const { loadState } = await import('./storage');
    await expect(loadState()).rejects.toThrow('not been overwritten');
    await expect(loadState()).rejects.toThrow('read failure');
    expect(bridge.write).not.toHaveBeenCalled();
  });
});
