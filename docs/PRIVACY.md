# Where your words go

Murmur does not include analytics or an application-hosted inference backend.

Desktop local mode processes audio with a downloaded Whisper model. Audio is held
in memory during dictation; the app does not intentionally write recordings to
disk. Transcript history and corrections are stored in local SQLite. Vocabulary,
including short correction evidence, is stored locally in the app settings area.
These files are not an encrypted vault and may be included in device backups.

If you select OpenAI or Groq transcription, audio and the selected vocabulary
hints are sent to that provider. If you select cloud cleanup, the transcript is
sent to that provider. ChatGPT cleanup sends text to OpenAI through the documented
Responses API with store:false; this is not a promise of zero provider retention.
Provider policies and account terms apply. ChatGPT login does not give Murmur
access to past ChatGPT conversations or memories.

API credentials and ChatGPT tokens use the operating system's credential store.
OAuth credentials are separate from the API-key controls. Sign out in Settings;
review authorized applications in your ChatGPT account if remote revocation is
unavailable. No credentials belong in bug reports.

Learning is off until enabled. Small user corrections from different saved
transcripts can teach a spelling; model-generated cleanup is never evidence.
Remove words, reset vocabulary, undo corrections, or delete individual dictations
to remove their learning evidence. Turning learning off stops using learned words
but does not delete them. Manually added words continue to be used. Vocabulary
exports omit correction evidence; review exports before sharing them.

Desktop Copy and hotkey insertion use the system clipboard. Mobile Copy and Share
move text outside the app at your request. Operating-system clipboard managers
and destination applications may retain it. Mobile storage and native recognition
constraints are described in mobile/README.md.

Murmur cannot observe edits made in arbitrary other applications. It does not
silently import contacts, record in the background on mobile, or train an acoustic
model from your voice. Any future sync, audio retention, analytics or external
correction observation should require a separate explained choice.
