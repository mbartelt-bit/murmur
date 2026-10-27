# Contributing to Murmur

Murmur is MIT-licensed. Small changes with a concrete user outcome are welcome.
Explain the problem, the resulting behavior, and the validation performed.

Desktop checks: `npm ci`, `npx vitest run`, `npm run build`, then
`cargo test --manifest-path src-tauri/Cargo.toml -- --skip secrets::tests::roundtrip_and_delete`.
The skipped test touches a real OS credential store; run it only in a deliberate
local test environment. The separate local-transcription test needs its documented
model/audio fixtures. Frontend build must precede native compilation.

Mobile checks: `cd mobile`, `npm ci`, `npm test`, `npm run build`; native build
instructions are in mobile/README.md. Desktop and mobile test environments are
isolated to prevent duplicate React runtimes.

For recognition changes, include representative consented or synthetic fixtures
and measure meaningful errors (especially names/numbers), not just a successful
HTTP request. For UI changes, test keyboard operation, text enlargement, reduced
motion and error recovery. Native screen-reader/device tests remain necessary.

Use synthetic text in screenshots/tests. Never include API keys, OAuth tokens,
private transcripts or personal audio in issues, logs or fixtures. Report security
issues privately through the repository owner's contact channel rather than
posting a working credential or sensitive reproduction publicly.

See docs/PRODUCT-PLAN.md for priorities and release gates.
