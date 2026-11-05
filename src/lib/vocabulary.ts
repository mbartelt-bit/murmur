import { invoke } from "@tauri-apps/api/core";
export interface Word {
  term: string;
  source: string;
  enabled: boolean;
  evidence: Record<string, string>;
}
export interface Vocabulary {
  learning: boolean;
  terms: Word[];
}
export const getVocabulary = () => invoke<Vocabulary>("get_vocabulary");
export const setLearning = (enabled: boolean) =>
  invoke<Vocabulary>("set_learning", { enabled });
export const addWord = (term: string) =>
  invoke<Vocabulary>("add_word", { term });
export const removeWord = (term: string) =>
  invoke<Vocabulary>("remove_word", { term });
export const resetVocabulary = () => invoke<Vocabulary>("reset_vocabulary");
export const learnCorrection = (id: number, before: string, after: string) =>
  invoke<Vocabulary>("learn_correction", { id, before, after });
