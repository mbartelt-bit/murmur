import { describe, it, expect } from 'vitest';
import { initialState, newDraft, saveDraft, rememberTerm, correctedTerm, decodeState, deleteDraft, hints, exportVocabulary } from './domain';
describe('personal vocabulary', () => {
  it('only learns after two different corrected dictations and never from repeated saves', () => {
    let s = initialState(); s.learning = true; s.draft.raw = 'Meet Mark tomorrow'; s.draft.text = 'Meet Marc tomorrow';
    s = saveDraft(s); expect(s.terms[0].enabled).toBe(false);
    s = saveDraft(s); expect(s.terms[0].observations).toBe(1);
    s.draft = { ...newDraft(), raw: 'Ask Mark tomorrow', text: 'Ask Marc tomorrow' };
    s = saveDraft(s); expect(s.terms[0]).toMatchObject({ observations: 2, enabled: true, term: 'Marc' });
    s.terms[0].enabled = false; s.terms[0].userDisabled = true;
    s.draft = { ...newDraft(), raw: 'Ask Mark tomorrow', text: 'Ask Marc tomorrow' };
    expect(saveDraft(s).terms[0].enabled).toBe(false);
  });
  it('does not learn without consent, from punctuation, insertions or rewrites', () => {
    const s = initialState(); s.draft.raw = 'Hello Mark'; s.draft.text = 'Hello Marc';
    expect(saveDraft(s).terms).toEqual([]);
    expect(correctedTerm('Hello Mark', 'Hello Mark.')).toBeNull();
    expect(correctedTerm('Hello', 'Hello Marc')).toBeNull();
    expect(correctedTerm('This is my original long sentence', 'Completely rewritten different long sentence here')).toBeNull();
  });
  it('uses bounded hints and exports without private correction evidence', () => {
    let terms = rememberTerm([], 'Murmur'); terms = rememberTerm(terms, 'Murmur');
    expect(terms).toHaveLength(1); expect(hints(terms)).toEqual(['Murmur']);
    expect(exportVocabulary(terms)).not.toContain('evidence');
    expect(hints(Array.from({length: 100}, (_, i) => ({...terms[0], term: `Term ${i}`})))).toHaveLength(80);
  });
  it('preserves saved edits and rejects corrupt storage without silently resetting', () => {
    const s = initialState(); s.draft.text = 'A saved thought';
    expect(decodeState(JSON.stringify(saveDraft(s))).draft.text).toBe('A saved thought');
    expect(() => decodeState('{"version":1}')).toThrow();
  });
  it('retracts previous evidence when a draft is reverted, changed or deleted', () => {
    let s = initialState(); s.learning = true;
    s.draft = { ...newDraft(), raw: 'Meet Mark', text: 'Meet Marc' }; s = saveDraft(s);
    const first = s.draft;
    s.draft = { ...newDraft(), raw: 'Meet Mark', text: 'Meet Marc' }; s = saveDraft(s);
    expect(s.terms[0].enabled).toBe(true);
    s.draft = { ...first, text: first.raw }; s = saveDraft(s);
    expect(s.terms[0]).toMatchObject({ observations: 1, enabled: false });
    s.draft = { ...first, text: 'Meet Marque' }; s = saveDraft(s);
    expect(s.terms.map(t => [t.term, t.observations])).toEqual([['Marc', 1], ['Marque', 1]]);
    s = deleteDraft(s, first.id);
    expect(s.terms.map(t => t.term)).toEqual(['Marc']);
    expect(s.draft.text).toBe('');
    expect(s.draft.id).not.toBe(first.id);
  });
  it('pauses learned hints when learning is off and retains explicit user choices', () => {
    let s = initialState(); s.learning = true;
    s.draft = { ...newDraft(), raw: 'Meet Mark', text: 'Meet Marc' }; s = saveDraft(s);
    s.terms[0].userEnabled = true; s.terms[0].enabled = true;
    s = saveDraft(s); expect(s.terms[0].enabled).toBe(true);
    s.terms = rememberTerm(s.terms, 'Murmur');
    expect(hints(s.terms, false)).toEqual(['Murmur']);
    expect(hints(s.terms, true)).toContain('Marc');
  });

});
