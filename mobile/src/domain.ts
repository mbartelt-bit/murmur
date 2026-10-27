export type Term = { term: string; source: 'manual' | 'learned'; observations: number; enabled: boolean; userDisabled?: boolean; userEnabled?: boolean; evidence: string[] };
export type Draft = { id: string; text: string; raw: string; createdAt: string };
export type State = { version: 1; draft: Draft; history: Draft[]; terms: Term[]; learning: boolean; locale: string; onboarded: boolean };
export const newDraft = (): Draft => ({ id: crypto.randomUUID(), text: '', raw: '', createdAt: new Date().toISOString() });
export const initialState = (): State => ({ version: 1, draft: newDraft(), history: [], terms: [], learning: false, locale: 'en-US', onboarded: false });
const normalize = (s: string) => s.trim().replace(/\s+/gu, ' ').normalize('NFC');
export function validTerm(value: string): string | null {
  const term = normalize(value);
  return term.length > 0 && term.length <= 80 && !/[\u0000-\u001f\u007f]/u.test(term) ? term : null;
}
// Learn only a small changed span, never an entire rewrite. No text replacements.
export function correctedTerm(before: string, after: string): string | null {
  const words = (s: string) => s.trim().split(/\s+/u).filter(Boolean);
  const a = words(before), b = words(after);
  if (!a.length || !b.length) return null;
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  let endA = a.length, endB = b.length;
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) { endA--; endB--; }
  if (endA === start || endB === start || endA - start > 3 || endB - start > 3) return null;
  const clean = (s: string) => s.replace(/^[\p{P}\p{S}]+|[\p{P}\p{S}]+$/gu, '');
  const previous = clean(a.slice(start, endA).join(' '));
  const replacement = clean(b.slice(start, endB).join(' '));
  if (previous.toLocaleLowerCase() === replacement.toLocaleLowerCase()) return null;
  if (!/\p{L}/u.test(replacement)) return null;
  return validTerm(replacement);
}
export function rememberTerm(terms: Term[], value: string): Term[] {
  const term = validTerm(value);
  if (!term) throw new Error('Use a word or short phrase of 1–80 characters.');
  const key = term.toLocaleLowerCase();
  const existing = terms.find(t => t.term.toLocaleLowerCase() === key);
  if (!existing && terms.length >= 500) throw new Error('Your dictionary holds 500 terms. Remove a term to add another.');
  return [...terms.filter(t => t !== existing), { term, source: 'manual', observations: existing?.observations ?? 0, enabled: true, evidence: existing?.evidence ?? [] }];
}
export function retractEvidence(terms: Term[], draftId: string): Term[] {
  return terms.flatMap(t => {
    if (!t.evidence.includes(draftId)) return [t];
    const evidence = t.evidence.filter(id => id !== draftId);
    if (!evidence.length && t.source === 'learned' && !t.userEnabled && !t.userDisabled) return [];
    return [{ ...t, evidence, observations: evidence.length,
      enabled: !t.userDisabled && (t.source === 'manual' || !!t.userEnabled || evidence.length >= 2) }];
  });
}
export function deleteDraft(state: State, id: string): State {
  return { ...state, draft: state.draft.id === id ? newDraft() : state.draft, history: state.history.filter(d => d.id !== id), terms: retractEvidence(state.terms, id) };
}
export function saveDraft(state: State): State {
  const draft = { ...state.draft, text: state.draft.text.trim() };
  if (!draft.text) throw new Error('Add some words before saving.');
  // A draft contributes only its latest saved correction, never its edit history.
  let terms = retractEvidence(state.terms, draft.id);
  const candidate = state.learning ? correctedTerm(draft.raw, draft.text) : null;
  if (candidate) {
    const found = terms.find(t => t.term.toLocaleLowerCase() === candidate.toLocaleLowerCase());
    if (found || terms.length < 500) {
      const evidence = [...(found?.evidence ?? []), draft.id].slice(-200);
      const observations = evidence.length;
      const next: Term = { term: found?.source === 'manual' ? found.term : candidate,
        source: found?.source ?? 'learned', observations, evidence,
        enabled: !found?.userDisabled && (found?.source === 'manual' || !!found?.userEnabled || observations >= 2),
        userDisabled: found?.userDisabled ?? false, userEnabled: found?.userEnabled ?? false };
      terms = [...terms.filter(t => t !== found), next];
    }
  }
  return { ...state, draft, terms, history: [draft, ...state.history.filter(item => item.id !== draft.id)].slice(0, 100) };
}
export function hints(terms: Term[], learning = true): string[] {
  let length = 0;
  return terms.filter(t => t.enabled && (learning || t.source === 'manual')).sort((a, b) => b.observations - a.observations).map(t => t.term).filter(term => {
    if (length + term.length > 1500) return false;
    length += term.length;
    return true;
  }).slice(0, 80);
}
export function exportVocabulary(terms: Term[]): string {
  return JSON.stringify({ version: 1, terms: terms.map(({ term, source, observations, enabled }) => ({ term, source, observations, enabled })) }, null, 2);
}
export function decodeState(value: string): State {
  const s: unknown = JSON.parse(value);
  const record = (x: unknown): x is Record<string, unknown> => !!x && typeof x === 'object';
  const draft = (x: unknown): x is Draft => record(x) && typeof x.id === 'string' && typeof x.text === 'string' && typeof x.raw === 'string' && typeof x.createdAt === 'string';
  if (!record(s) || s.version !== 1 || !draft(s.draft) || !Array.isArray(s.history) || s.history.length > 100 || !s.history.every(draft)
      || !Array.isArray(s.terms) || s.terms.length > 500 || !s.terms.every(t => record(t) && typeof t.term === 'string' && validTerm(t.term) === t.term
        && ['manual', 'learned'].includes(t.source as string) && typeof t.observations === 'number' && Number.isInteger(t.observations) && t.observations >= 0
        && typeof t.enabled === 'boolean' && (t.userDisabled === undefined || typeof t.userDisabled === 'boolean') && (t.userEnabled === undefined || typeof t.userEnabled === 'boolean') && Array.isArray(t.evidence) && t.evidence.length <= 200 && t.evidence.every((v: unknown) => typeof v === 'string'))
      || typeof s.learning !== 'boolean' || typeof s.locale !== 'string' || typeof s.onboarded !== 'boolean') {
    throw new Error('Saved data could not be read. It has not been overwritten.');
  }
  return s as State;
}
