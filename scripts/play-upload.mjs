#!/usr/bin/env node
/**
 * Headless Google Play upload for Murmur (adapted from ARKHE's proven script).
 *
 *   node scripts/play-upload.mjs --aab <path> [--package com.murmur.app]
 *                                [--track internal] [--status completed|draft|inProgress|halted]
 *                                [--rollout 0.1] [--notes <file>] [--dry-run]
 *
 * Dependency-free: the service account only needs an RS256 JWT, which node:crypto mints.
 *
 * Auth: the service-account JSON at $PLAY_SERVICE_ACCOUNT, defaulting to
 * ~/murmur-android-signing/play-service-account.json and, failing that,
 * ~/arkhe-android-signing/play-service-account.json (the same Google Play developer account
 * owns both apps, so one service account can be granted access to both in Play Console →
 * Users and permissions). Never commit or print it.
 *
 * Defaults are tuned for TestFlight-style internal testing: track `internal`, status
 * `completed` (internal testers get the build immediately; nothing public happens on that
 * track). Pass --track production --status draft for a real release.
 */
import { readFileSync, existsSync, statSync } from "node:fs";
import { createSign } from "node:crypto";
import { join } from "node:path";
import { homedir } from "node:os";

const HOME = homedir();
const API = "https://androidpublisher.googleapis.com";
const SCOPE = "https://www.googleapis.com/auth/androidpublisher";

const c = { red: "\x1b[31m", green: "\x1b[32m", yellow: "\x1b[33m", dim: "\x1b[2m", off: "\x1b[0m" };
const ok = (m) => console.log(`${c.green}✓${c.off} ${m}`);
const warn = (m) => console.log(`${c.yellow}!${c.off} ${m}`);
const die = (m, hint) => {
  console.error(`${c.red}✗${c.off} ${m}`);
  if (hint) console.error(`  ${c.dim}${hint}${c.off}`);
  process.exit(1);
};

// ─────────────────────────────── args ────────────────────────────────────────
const args = process.argv.slice(2);
const flag = (name, fallback = null) => {
  const i = args.indexOf(`--${name}`);
  return i === -1 ? fallback : args[i + 1];
};
const has = (name) => args.includes(`--${name}`);

const aabPath = flag("aab");
const PACKAGE = flag("package", "com.murmur.app");
const track = flag("track", "internal");
const notesFile = flag("notes");
const status = flag("status", track === "internal" ? "completed" : "draft");
const rollout = flag("rollout");
const dryRun = has("dry-run");

if (!aabPath) die("--aab <path> is required");
if (!existsSync(aabPath)) die(`no .aab at ${aabPath}`);
if (!["draft", "completed", "inProgress", "halted"].includes(status)) {
  die(`--status must be draft | completed | inProgress | halted (got "${status}")`);
}
if (status === "inProgress" && !rollout) die("--status inProgress needs --rollout (e.g. 0.1)");

// ──────────────────────────────── auth ───────────────────────────────────────
function keyFile() {
  const candidates = [
    process.env.PLAY_SERVICE_ACCOUNT,
    join(HOME, "murmur-android-signing/play-service-account.json"),
    join(HOME, "arkhe-android-signing/play-service-account.json"),
  ].filter(Boolean);
  const found = candidates.find((p) => existsSync(p));
  if (!found) {
    die("no Play service-account key found",
      `looked at: ${candidates.join(", ")}\n` +
      "  Play Console → Setup → API access → service accounts; grant it Release manager on Murmur.");
  }
  return found;
}

async function accessToken() {
  const key = JSON.parse(readFileSync(keyFile(), "utf8"));
  if (!key.client_email || !key.private_key) die("service-account file lacks client_email/private_key");
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const iat = Math.floor(Date.now() / 1000);
  const header = b64({ alg: "RS256", typ: "JWT" });
  const claim = b64({ iss: key.client_email, scope: SCOPE, aud: "https://oauth2.googleapis.com/token", exp: iat + 3600, iat });
  const sig = createSign("RSA-SHA256").update(`${header}.${claim}`).sign(key.private_key, "base64url");
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${header}.${claim}.${sig}` }),
  });
  const body = await r.json();
  if (!r.ok) die(`token request failed (${r.status})`, `${body.error ?? ""} ${body.error_description ?? ""}`.trim());
  return body.access_token;
}

// ──────────────────────────────── api ────────────────────────────────────────
async function api(token, method, path, { body, raw, contentType } = {}) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      ...(contentType ? { "Content-Type": contentType } : {}),
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: raw ?? (body ? JSON.stringify(body) : undefined),
  });
  const text = await res.text();
  let parsed;
  try { parsed = text ? JSON.parse(text) : {}; } catch { parsed = { raw: text }; }
  if (!res.ok) die(`${method} ${path} → ${res.status}`, parsed?.error?.message ?? text.slice(0, 400));
  return parsed;
}

function releaseNotes() {
  if (!notesFile) return undefined;
  if (!existsSync(notesFile)) die(`no notes file at ${notesFile}`);
  const text = readFileSync(notesFile, "utf8").trim();
  if (text.length > 500) die(`release notes are ${text.length} chars; Play's limit is 500`);
  return [{ language: "en-US", text }];
}

// ──────────────────────────────── main ───────────────────────────────────────
const size = (statSync(aabPath).size / 1024 / 1024).toFixed(1);
console.log(`\n── Play upload (${PACKAGE}) ──`);
console.log(`${c.dim}bundle${c.off}  ${aabPath} (${size} MB)`);
console.log(`${c.dim}track${c.off}   ${track}`);
console.log(`${c.dim}status${c.off}  ${status}${rollout ? ` @ ${Number(rollout) * 100}%` : ""}`);
const notes = releaseNotes();
if (dryRun) warn("--dry-run: authenticating and reading track state, uploading nothing");

const token = await accessToken();
ok("authenticated as the Play service account");

const base = `/androidpublisher/v3/applications/${PACKAGE}`;
const edit = await api(token, "POST", `${base}/edits`);
const editId = edit.id;
const current = await api(token, "GET", `${base}/edits/${editId}/tracks/${track}`).catch(() => ({}));
const live = (current.releases ?? []).flatMap((r) => r.versionCodes ?? []).map(Number).sort((a, b) => a - b);
if (live.length) ok(`${track} currently serves versionCode ${live.join(", ")}`);

if (dryRun) {
  await api(token, "DELETE", `${base}/edits/${editId}`);
  ok("dry run complete — edit discarded, nothing changed");
  process.exit(0);
}

const bundle = await api(token, "POST",
  `/upload/androidpublisher/v3/applications/${PACKAGE}/edits/${editId}/bundles?uploadType=media`,
  { raw: readFileSync(aabPath), contentType: "application/octet-stream" });
ok(`uploaded versionCode ${bundle.versionCode}`);

const release = { versionCodes: [String(bundle.versionCode)], status };
if (notes) release.releaseNotes = notes;
if (rollout) release.userFraction = Number(rollout);
await api(token, "PUT", `${base}/edits/${editId}/tracks/${track}`, { body: { track, releases: [release] } });
ok(`${track} track set to ${status}`);
await api(token, "POST", `${base}/edits/${editId}:commit`);
ok("committed");

console.log(`\nversionCode ${bundle.versionCode} is on the ${track} track as ${c.green}${status}${c.off}.` +
  (track === "internal"
    ? "\nInternal testers can install it from the Play Console's internal-testing link within a few minutes."
    : status === "draft"
      ? "\nIt is NOT live. Roll it out in the Play Console or re-run with --status completed."
      : "\nIt is live."));
