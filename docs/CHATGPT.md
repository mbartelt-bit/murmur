# ChatGPT text cleanup (experimental)

Murmur can use an eligible ChatGPT plan to clean up **text after transcription**.
It uses OpenAI's documented open-source Sign in with ChatGPT flow. It does not
send audio through ChatGPT login, access ChatGPT conversations, import memories,
or substitute subscription tokens into the audio API.

This integration is experimental until an eligible user's real sign-in, token
renewal, model availability and completed cleanup have been tested. Automated
checks do not establish account eligibility or live service availability.

## Connect

1. Choose local transcription if you want speech recognition to stay on-device.
2. In ChatGPT connection, choose **Continue with ChatGPT**. Murmur opens the system
   browser and listens temporarily on an ephemeral port at `127.0.0.1`.
3. Review OpenAI's consent screen. ChatGPT plan use requires separate permission;
   signing in for identity alone does not enable cleanup.
4. Choose **Load available models**, then a cleanup model available to the account.
5. Select **ChatGPT** as the cleanup engine. Transcribed text is now sent to OpenAI
   for punctuation/capitalization cleanup; raw audio still follows the separately
   selected transcription engine.

A model is intentionally not silently chosen based on a hard-coded model name.
Account catalogs and availability differ. No request switches to a paid API key
if the ChatGPT plan reaches its limits or fails.

Multiple account/workspace registrations are separate. The account label includes
a registration suffix so identical email addresses can be distinguished. Adding
an account requires a fresh verified sign-in. Reauthorization reuses that
registration's issued client ID and the installation's stable host ID.

**Sign out** attempts remote session revocation, then removes local tokens. The
account registration is retained for later reauthorization. If remote revocation
cannot be confirmed, Murmur says so and links to ChatGPT settings. Sign out does
not delete transcript history or vocabulary. Use their own controls to remove
that data.

## Security and failure handling

- Authorization Code with S256 PKCE, fresh random state and nonce per attempt.
- Listener is bound only to loopback, with a three-minute sign-in deadline and
  bounded request lines. Duplicate callback parameters, wrong state, wrong path,
  and changed client registrations are rejected. Cancellation invalidates the
  attempt; late callbacks cannot install credentials.
- OpenID identity signature is verified against OpenAI's discovered JWKS using
  `jsonwebtoken`, restricted to RS256/ES256. Issuer, audience, expiry, issued-at,
  optional not-before, nonce and authorized party are checked. Returning
  registrations must retain the same verified subject.
- Discovery endpoints are restricted to HTTPS on `auth.openai.com`; HTTP client
  redirects are disabled. Credentials and authorization URLs are never returned
  through IPC or logged.
- Credentials use the OS keyring service `com.murmur.app.chatgpt`, distinct from
  Murmur's generic provider-key service. No browser storage or plaintext fallback
  is used. A locked or unsupported credential store produces an error. Host IDs
  and registrations are persisted with the vault. Base64 chunks fit within small
  OS credential limits; a manifest commits each complete generation atomically.
  Superseded chunks are removed on a best-effort basis. A crash during saving
  may leave orphaned entries protected by the OS credential store.
- Access tokens renew near expiry. Rotating refreshes are serialized within the
  app process and updated with their scopes/expiry. Run a single Murmur process
  per user; the desktop app should enforce single-instance operation.
- Responses requests use `store:false`, `stream:true`, explicit user input and
  cleanup instructions. The adapter accepts only final assistant text in a
  `response.completed` event. Partial, failed, refused and interrupted output is
  never accepted as a completed transcript.
- All HTTP requests have connection and total deadlines, and response bodies have
  a size limit. Account changes/sign-out invalidate in-flight cleanup results.
- Errors must preserve the raw transcript and show a user-visible notice. There
  is no silent switch to another paid billing route.

## Developer integration

Rust dependencies: `base64 0.22`, `sha2 0.10`, `rand 0.8`, `jsonwebtoken 9`,
`uuid 1` with `v4`. Existing `reqwest`, `keyring`, `zeroize`, `serde` and Tauri
provide the remaining dependencies.

Register module `chatgpt` and these commands:

- `chatgpt_status`
- `chatgpt_sign_in(client_id: Option<String>)` (`null` means add a new account)
- `chatgpt_cancel_sign_in`
- `chatgpt_models`
- `chatgpt_select_account(client_id)`
- `chatgpt_select_model(model)`
- `chatgpt_sign_out(client_id)`

Render `ChatGptConnection` in settings. Add `chatgpt` to cleanup engine settings.
Call `chatgpt::clean(raw)` from the dictation worker and handle its `Result` by
preserving the raw text on failure, with a visible notice. Do not add ChatGPT to
speech-to-text engines. Sign-in alone does not change the user's cleanup engine.

The local private key in `src-tauri/src/chatgpt/fixtures/test-only-ec.pem` is a
public, generated **test-only** signing fixture, not a user credential. Its sole
purpose is verifying signature rejection and claim validation in offline tests.

## Required live validation before a release claim

- Eligible real account: consent, successful callback, selected model, completed
  cleanup and observed text preservation/latency.
- Declined consent, absent plan scope, usage limits, unsupported account/region.
- Relaunch and token refresh; account/workspace switching; revoked session.
- Cancel before callback and while code exchange is in progress.
- OS keyring behavior in signed macOS, Windows and Linux packages. Windows
  credential-size limits are handled with bounded chunks, but real Credential
  Manager and Secret Service behavior still needs packaged-platform testing.
- Screen-reader and keyboard operation of the connection UI.
- Verify the distribution's single-instance guard; refresh locks do not coordinate
  independent processes.

## Implementation handoff / verification

As of October 27, 2026: implementation is in `src-tauri/src/chatgpt/` and
`src/components/ChatGptConnection.tsx`; no real account login or API inference
has been performed. Fourteen Rust tests cover PKCE, callback binding, actual JWT
signature/claim validation, scope reduction, completed-stream requirements,
transaction rollback and atomic chunked credential persistence. Three component
tests cover native sign-in/cancel, denied plan scope and identity errors.
`npx tsc --noEmit` passes. Parent integrates commands, engine choice and UI.

Account/model/sign-in changes commit only after persistence succeeds. Rotated
refresh credentials and sign-out token removal deliberately remain in memory
if persistence fails; a storage-pending warning is surfaced and the next
inference retries persistence before proceeding. This avoids replaying a
consumed refresh token. Restart after a credential-store failure may require
reauthorization. No secrets are present in source other than the explicitly
public test-only signing fixture. No running operations remain after tests.

## Sources (checked October 27, 2026)

- [Registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Accounts, refresh and revocation](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
- [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [Preview limitations, including no audio or transcription](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [Token reference](https://developers.openai.com/siwc/token-sharing-open-source/token-reference)
- [OIDC discovery and identity validation](https://developers.openai.com/siwc/website)
