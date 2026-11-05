import { useEffect, useRef, useState } from 'react';
import { Capacitor, type PluginListenerHandle } from '@capacitor/core';
import { Clipboard } from '@capacitor/clipboard';
import { Share } from '@capacitor/share';
import { correctedTerm, deleteDraft, exportVocabulary, hints, initialState, newDraft, rememberTerm, saveDraft, type State } from './domain';
import { loadState, persistState } from './storage';
import { Speech, type SpeechEvent } from './speech';
import './style.css';

type Tab = 'dictate' | 'library' | 'words' | 'settings';
type Phase = 'idle' | 'starting' | 'recording' | 'finishing';
const languages = [['en-US', 'English (US)'], ['en-GB', 'English (UK)'], ['es-ES', 'Español'], ['fr-FR', 'Français'], ['de-DE', 'Deutsch'], ['it-IT', 'Italiano'], ['pt-BR', 'Português'], ['ja-JP', '日本語']];
function Icon({ name }: { name: Tab | 'mic' | 'stop' }) {
  const paths = { dictate: 'M12 3v18M7 7v10M17 7v10M3 10v4M21 10v4', library: 'M5 3h14v18H5zM8 7h8M8 11h8M8 15h5', words: 'M4 19 10 5h4l6 14M7 14h10', settings: 'M4 7h16M4 17h16M8 4v6M16 14v6', mic: 'M9 5a3 3 0 0 1 6 0v6a3 3 0 0 1-6 0zM5 10v1a7 7 0 0 0 14 0v-1M12 18v4M8 22h8', stop: 'M6 6h12v12H6z' };
  return <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={paths[name]}/></svg>;
}
export default function App() {
  const [data, setData] = useState<State | null>(null);
  const current = useRef<State | null>(null);
  const [tab, setTab] = useState<Tab>('dictate');
  const [phase, setPhase] = useState<Phase>('idle');
  const [notice, setNotice] = useState('');
  const [error, setError] = useState('');
  const [loadError, setLoadError] = useState(false);
  const [term, setTerm] = useState('');
  const [search, setSearch] = useState('');
  const [clearConfirm, setClearConfirm] = useState(false);
  const [available, setAvailable] = useState(false);
  const [unavailableReason, setUnavailableReason] = useState('Checking on-device speech…');
  const session = useRef<string | null>(null);
  const [listenersReady, setListenersReady] = useState(false);
  const savedVersion = useRef(0);
  const [saveFailed, setSaveFailed] = useState(false);
  const phaseRef = useRef<Phase>('idle');
  const updatePhase = (value: Phase) => { phaseRef.current = value; setPhase(value); };
  const update = (fn: (s: State) => State) => {
    if (!current.current) return;
    const next = fn(current.current); current.current = next; setData(next);
    const version = ++savedVersion.current;
    void persistState(next).then(() => { if (version === savedVersion.current) setSaveFailed(false); }).catch(() => {
      setSaveFailed(true);
      setError('Your changes could not be saved on this device. Copy your draft before closing Murmur.');
    });
  };
  useEffect(() => {
    let live = true;
    void loadState().then(s => { if (live) { current.current = s; setData(s); } }).catch(() => {
      if (live) { setError('Saved data could not be opened. It has not been overwritten. Restart Murmur to try again.'); setLoadError(true); }
    });
    return () => { live = false; };
  }, []);
  useEffect(() => {
    let live = true;
    if (!data) return;
    if (!Capacitor.isNativePlatform()) {
      setUnavailableReason('Recording is available in the iPhone and Android apps. You can explore drafts and vocabulary here.');
      return;
    }
    setAvailable(false);
    void Speech.available({ locale: data.locale }).then(result => {
      if (live) { setAvailable(result.available); setUnavailableReason(result.reason ?? 'On-device speech is not available for this language. Try another language or install its speech model in system settings.'); }
    }).catch(() => { if (live) setUnavailableReason('Speech is unavailable. Reopen the app or check device speech settings.'); });
    return () => { live = false; };
  }, [data?.locale]);
  useEffect(() => {
    let live = true;
    const handles: PluginListenerHandle[] = [];
    if (!Capacitor.isNativePlatform()) return;
    const matches = (e: SpeechEvent) => live && e.sessionId === session.current;
    void (async () => {
      for (const [name, fn] of [
        ['result', (e: SpeechEvent) => { if (matches(e) && typeof e.text === 'string') { update(s => ({ ...s, draft: { ...s.draft, raw: e.text!, text: e.text! } })); if (e.final) { updatePhase('idle'); session.current = null; setNotice('Ready to review. Make any corrections, then save.'); } } }],
        ['state', (e: SpeechEvent) => { if (matches(e) && e.state) { updatePhase(e.state); if (e.state === 'idle') session.current = null; } }],
        ['failure', (e: SpeechEvent) => { if (matches(e)) { updatePhase('idle'); session.current = null; setError(e.message ?? 'Speech recognition stopped. Your draft is still here.'); } }],
      ] as const) {
        const handle = await Speech.addListener(name, fn);
        if (!live) await handle.remove(); else handles.push(handle);
      }
      if (live) setListenersReady(true);
    })().catch(() => { if (live) setError('Could not connect to speech recognition. Restart Murmur.'); });
    return () => { live = false; handles.forEach(h => void h.remove()); session.current = null; void Speech.cancel().catch(() => {}); };
  }, []);
  const start = async () => {
    if (phaseRef.current !== 'idle' || !current.current) return;
    setError(''); setNotice('');
    // Preserve the current draft before creating a new recording.
    if (current.current.draft.text.trim()) update(saveDraft);
    update(s => ({ ...s, draft: newDraft() }));
    const id = crypto.randomUUID(); session.current = id; updatePhase('starting');
    try { await Speech.start({ sessionId: id, locale: current.current!.locale, hints: hints(current.current!.terms, current.current!.learning) }); }
    catch (e) { if (session.current === id) { session.current = null; updatePhase('idle'); setError(e instanceof Error ? e.message : 'Could not start speech recognition. Check microphone permission in Settings.'); } }
  };
  const stop = async () => {
    updatePhase('finishing');
    try { await Speech.stop(); } catch { updatePhase('idle'); session.current = null; setError('Could not finish recognition. Your latest words are still in the draft.'); }
  };
  const cancel = async () => {
    session.current = null; updatePhase('idle');
    try { await Speech.cancel(); setNotice('Recording stopped. Any words already recognized are kept in your draft.'); }
    catch { setError('Could not release speech recognition. Close Murmur to stop the microphone.'); }
  };
  const copy = async (text: string, message = 'Copied. Paste wherever you need it.') => {
    try { await Clipboard.write({ string: text }); setNotice(message); } catch { setError('Could not copy. Select the text to copy it manually.'); }
  };
  const share = async (text: string, title = 'From Murmur') => {
    try { await Share.share({ title, text }); } catch { setNotice('Sharing closed. Your words are still here.'); }
  };
  const save = () => { try { update(saveDraft); setNotice('Saved to your library.'); } catch (e) { setError((e as Error).message); } };
  const addWord = (value: string) => { try { update(s => ({ ...s, terms: rememberTerm(s.terms, value) })); setTerm(''); setNotice(`Remembered “${value.trim()}”.`); } catch (e) { setError((e as Error).message); } };
  const active = phase !== 'idle';
  if (!data) return <main className="loading"><span className="brand-symbol">m</span><h1>Murmur</h1><p role={loadError ? 'alert' : 'status'}>{error || 'Opening your space…'}</p></main>;
  const candidate = correctedTerm(data.draft.raw, data.draft.text);
  const count = data.draft.text.trim().split(/\s+/u).filter(Boolean).length;
  const titles = { dictate: 'A little space for\nyour voice.', library: 'Your words,\nwithin reach.', words: 'Sounds like you.\nSpelled like you.', settings: 'Make yourself\nat home.' };
  return <div className="app-shell">
    <header className="brand"><span className="brand-symbol" aria-hidden="true">m</span><span>Murmur</span><span className="device-pill">On your device</span></header>
    <main id="main-content">
      <p className="eyebrow">{tab === 'dictate' ? 'SAY IT YOUR WAY' : tab === 'words' ? 'PERSONAL VOCABULARY' : tab.toUpperCase()}</p>
      <h1>{titles[tab]}</h1>
      {!data.onboarded && <section className="welcome" aria-label="Welcome to Murmur"><p>Speak a thought. Make it yours. Take it anywhere.</p><p className="muted">Speech recognition stays on this device. Murmur keeps text drafts, not audio recordings. Your phone needs a supported speech language installed.</p><button className="text-button" onClick={() => update(s => ({ ...s, onboarded: true }))}>Got it, let’s begin <span aria-hidden="true">↗</span></button></section>}
      {error && <div className="message error" role="alert"><p>{error}</p><button onClick={() => setError('')}>Dismiss</button></div>}
      {saveFailed && <div className="message error"><p>Changes are not saved yet.</p><button onClick={() => update(s => ({ ...s }))}>Retry saving</button></div>}
      <p className="notice" role="status" aria-live="polite">{notice}</p>
      {active && tab !== 'dictate' && <section className="message recording-banner" aria-label="Active recording"><p role="status">{phase === 'recording' ? 'Murmur is listening' : phase === 'starting' ? 'Starting microphone' : 'Finishing dictation'}</p><button disabled={phase !== 'recording'} onClick={() => void stop()}>Finish</button><button onClick={() => void cancel()}>Cancel</button></section>}
      {tab === 'dictate' && <>
        <section className={`capture-card ${active ? 'is-recording' : ''}`} aria-label="Dictation">
          <div className="capture-top"><span className="status-dot"/><span role="status">{phase === 'starting' ? 'Asking for microphone access' : phase === 'recording' ? 'Listening to you' : phase === 'finishing' ? 'Finishing your words' : 'Ready when you are'}</span><span className="small-label">{data.locale}</span></div>
          <div className="wave" aria-hidden="true">{Array.from({ length: 31 }, (_, i) => <i key={i} style={{ height: `${12 + Math.sin(i * 0.65) ** 2 * 46}px` }}/>)}</div>
          <button className="record-button" disabled={!available || !listenersReady || phase === 'starting' || phase === 'finishing'} onClick={() => void (phase === 'recording' ? stop() : start())}><Icon name={phase === 'recording' ? 'stop' : 'mic'}/>{phase === 'recording' ? 'Finish dictation' : phase === 'starting' ? 'Starting…' : phase === 'finishing' ? 'Finishing…' : 'Start dictation'}</button>
          {active ? <button className="text-button cancel" onClick={() => void cancel()}>Cancel recording</button> : <p className="capture-note">{available ? 'Tap once to start. Tap again to finish.' : unavailableReason}</p>}
        </section>
        <section className="draft-card"><div className="section-heading"><h2>Your draft</h2><span>{count} {count === 1 ? 'word' : 'words'}</span></div><label className="sr-only" htmlFor="draft">Review and edit your dictation</label><textarea id="draft" maxLength={20000} value={data.draft.text} readOnly={active} onChange={e => update(s => ({ ...s, draft: { ...s.draft, text: e.target.value } }))} placeholder="Your words will appear here. You can also type a thought."/>
          {candidate && !active && <button className="remember" onClick={() => addWord(candidate)}>Remember “{candidate}” <span aria-hidden="true">+</span></button>}
          <div className="actions"><button className="primary" disabled={active || !data.draft.text.trim()} onClick={save}>Save draft</button><button disabled={active || !data.draft.text.trim()} onClick={() => void copy(data.draft.text)}>Copy</button><button disabled={active || !data.draft.text.trim()} onClick={() => void share(data.draft.text)}>Share</button></div>
          {!!data.draft.text.trim() && !active && <button className="text-button" onClick={() => { update(s => ({ ...saveDraft(s), draft: newDraft() })); setNotice('Previous draft saved. A fresh page is ready.'); }}>Save & start fresh</button>}
        </section>
        <p className="privacy-note">A thought is yours until you share it. Copy and Share send only the text you choose.</p>
      </>}
      {tab === 'library' && <section><label htmlFor="search" className="field-label">Find a thought</label><input id="search" type="search" value={search} onChange={e => setSearch(e.target.value)} placeholder="Search your drafts"/>{data.history.length === 0 && <div className="empty"><Icon name="library"/><h2>A place for your thoughts.</h2><p>Saved dictations appear here. Keep a note, shape an idea, or pick up where you left off.</p><button onClick={() => setTab('dictate')}>Create your first draft</button></div>}
        {data.history.filter(d => d.text.toLocaleLowerCase().includes(search.toLocaleLowerCase())).map(d => <article className="history-card" key={d.id}><time dateTime={d.createdAt}>{new Date(d.createdAt).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}</time><p>{d.text}</p><div className="actions"><button disabled={active} onClick={() => { update(s => ({ ...(s.draft.text.trim() ? saveDraft(s) : s), draft: d })); setTab('dictate'); }}>Edit</button><button onClick={() => void copy(d.text)}>Copy</button><button className="danger" onClick={() => { update(s => deleteDraft(s, d.id)); setNotice('Removed from your library.'); }}>Delete</button></div></article>)}
        {!!data.history.length && !data.history.some(d => d.text.toLocaleLowerCase().includes(search.toLocaleLowerCase())) && <p className="empty">No drafts match that search.</p>}
      </section>}
      {tab === 'words' && <>
        <p className="intro">Names, places, and the words that make your world. These give speech recognition a little context.</p>
        {!data.learning && data.terms.some(t => t.source === 'learned') && <p className="muted">Learning is off. Only names you added manually are used as hints.</p>}
        <form className="word-form" onSubmit={e => { e.preventDefault(); addWord(term); }}><label className="field-label" htmlFor="term">Add a name or phrase</label><div className="input-row"><input id="term" maxLength={80} autoCapitalize="words" value={term} onChange={e => setTerm(e.target.value)} placeholder="e.g. Murmur"/><button className="primary" disabled={!term.trim()}>Add</button></div></form>
        <div className="section-heading"><h2>Your vocabulary</h2><span>{data.terms.filter(t => t.enabled && (data.learning || t.source === 'manual')).length} active</span></div>
        {!data.terms.length && <p className="empty">Start with a name that speech recognition often gets wrong.</p>}
        {[...data.terms].sort((a,b) => a.term.localeCompare(b.term)).map(t => <article className="term-row" key={t.term}><div><strong>{t.term}</strong><p>{t.source === 'manual' ? 'Added by you' : t.observations < 2 ? 'Learning · needs another correction' : `Learned from ${t.observations} corrections`}</p></div><button aria-label={`${t.enabled ? 'Pause' : 'Enable'} ${t.term}`} aria-pressed={t.enabled} onClick={() => update(s => ({ ...s, terms: s.terms.map(item => item.term === t.term ? { ...item, enabled: !item.enabled, userDisabled: item.enabled, userEnabled: !item.enabled } : item) }))}>{t.enabled ? 'Enabled' : 'Paused'}</button><button className="danger" aria-label={`Forget ${t.term}`} onClick={() => update(s => ({ ...s, terms: s.terms.filter(item => item.term !== t.term) }))}>Forget</button></article>)}
        {!!data.terms.length && <button className="wide" onClick={() => void share(exportVocabulary(data.terms), 'Murmur vocabulary')}>Export vocabulary</button>}
        <p className="privacy-note">Hints improve recognition; they never force a word into your transcript. Recognition support varies by phone and language.</p>
      </>}
      {tab === 'settings' && <>
        <section className="settings-card"><h2>Speech & language</h2><label className="field-label" htmlFor="language">Dictation language</label><select id="language" value={data.locale} disabled={active} onChange={e => update(s => ({ ...s, locale: e.target.value }))}>{languages.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select><p className="muted">Uses your phone’s on-device speech engine. If a language isn’t available, install its speech model in system settings. There is no cloud fallback.</p></section>
        <section className="settings-card"><h2>Learn from my corrections</h2><label className="switch-row"><span>Remember words I correct</span><input type="checkbox" checked={data.learning} onChange={e => update(s => ({ ...s, learning: e.target.checked }))}/></label><p className="muted">After the same spelling is corrected in two different saved drafts, Murmur adds it as a vocabulary hint. Only edits made here count. Review or forget words any time. Turning this off also pauses learned hints; names you add manually still apply.</p></section>
        <section className="settings-card"><h2>Private by design</h2><p className="muted">No account. No analytics. No stored audio. Drafts and vocabulary stay in this app’s device storage. The latest 100 saved drafts are kept; your device’s backup settings may include app data.</p><p className="muted">Mobile recording happens inside Murmur. Use Copy or Share to take text to another app. ChatGPT cleanup and cross-device sync are not included in this version.</p></section>
        <section className="settings-card"><h2>Your data, your choice</h2>{clearConfirm ? <div><p>Delete all drafts and vocabulary from this device? This cannot be undone.</p><div className="actions"><button disabled={active} className="danger" onClick={() => { update(() => ({ ...initialState(), onboarded: true })); setClearConfirm(false); setNotice('Your Murmur data has been cleared.'); }}>Delete everything</button><button onClick={() => setClearConfirm(false)}>Keep my data</button></div></div> : <button className="danger wide" disabled={active} onClick={() => setClearConfirm(true)}>Delete all local data</button>}</section>
        <p className="privacy-note">Murmur mobile · 0.1.0 preview<br/>Made for the way you speak.</p>
      </>}
    </main>
    <nav className="bottom-nav" aria-label="Main navigation">{(['dictate', 'library', 'words', 'settings'] as Tab[]).map(item => <button key={item} aria-current={tab === item ? 'page' : undefined} onClick={() => { setTab(item); setNotice(''); }}><Icon name={item}/><span>{item === 'words' ? 'Vocabulary' : item[0].toUpperCase() + item.slice(1)}</span></button>)}</nav>
  </div>;
}
