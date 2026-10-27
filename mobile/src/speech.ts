import { registerPlugin, type PluginListenerHandle } from '@capacitor/core';
export type SpeechEvent = { sessionId: string; text?: string; final?: boolean; state?: 'recording' | 'finishing' | 'idle'; message?: string };
interface SpeechPlugin {
  available(options: { locale: string }): Promise<{ available: boolean; reason?: string }>;
  start(options: { sessionId: string; locale: string; hints: string[] }): Promise<void>;
  stop(): Promise<void>;
  cancel(): Promise<void>;
  addListener(name: 'result' | 'state' | 'failure', callback: (event: SpeechEvent) => void): Promise<PluginListenerHandle>;
}
export const Speech = registerPlugin<SpeechPlugin>('MurmurSpeech');
