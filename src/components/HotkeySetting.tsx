import { useEffect, useRef, useState } from "react";
import { getHotkey, setHotkey } from "../lib/ipc";

// ── Accelerator helpers ───────────────────────────────────────────────────────

/**
 * Format a raw accelerator string (e.g. "control+alt+KeyD") into symbol form
 * (e.g. "⌃⌥D").  Order: ⌃⌥⇧⌘ then key.
 */
export function formatAccelerator(accel: string): string {
  const parts = accel.toLowerCase().split("+");
  const hasCtrl = parts.includes("control") || parts.includes("ctrl");
  const hasAlt = parts.includes("alt") || parts.includes("option");
  const hasShift = parts.includes("shift");
  const hasSuper =
    parts.includes("super") ||
    parts.includes("cmd") ||
    parts.includes("command");

  // The key is the last non-modifier token.
  const modTokens = new Set(["control", "ctrl", "alt", "option", "shift", "super", "cmd", "command"]);
  const keyToken = parts.find((p) => !modTokens.has(p)) ?? "";

  const keyLabel = formatKeyToken(keyToken);

  const symbols = [
    hasCtrl ? "⌃" : "",
    hasAlt ? "⌥" : "",
    hasShift ? "⇧" : "",
    hasSuper ? "⌘" : "",
    keyLabel,
  ].join("");

  return symbols;
}

/**
 * Convert a key token (W3C KeyboardEvent.code or parse-lowercased version) to
 * a display label.
 *
 * Examples: "keyd" → "D", "digit1" → "1", "space" → "Space", "arrowup" → "ArrowUp"
 */
export function formatKeyToken(token: string): string {
  const upper = token.toUpperCase();
  if (upper.startsWith("KEY") && upper.length === 4) {
    return upper.slice(3); // "KEYD" → "D"
  }
  if (upper.startsWith("DIGIT") && upper.length === 6) {
    return upper.slice(5); // "DIGIT1" → "1"
  }
  if (upper === "SPACE") return "Space";
  // Preserve original capitalisation for other tokens (e.g. ArrowUp, F12).
  return token.charAt(0).toUpperCase() + token.slice(1);
}

export interface KeyEventLike {
  ctrlKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
  metaKey: boolean;
  code: string;
}

/**
 * Build an accelerator string from a KeyboardEvent (or any KeyEventLike object).
 * Returns null if no modifier is held (bare key press).
 *
 * Format: ["Control","Alt","Shift","Super"].filter(present) joined by "+" then e.code.
 * Example: { ctrlKey:true, altKey:true, metaKey:false, shiftKey:false, code:"KeyD" }
 *          → "Control+Alt+KeyD"
 */
export function buildAccelerator(e: KeyEventLike): string | null {
  const mods: string[] = [];
  if (e.ctrlKey) mods.push("Control");
  if (e.altKey) mods.push("Alt");
  if (e.shiftKey) mods.push("Shift");
  if (e.metaKey) mods.push("Super");
  if (mods.length === 0) return null;
  return [...mods, e.code].join("+");
}

const PURE_MODIFIER_CODES = new Set([
  "ControlLeft", "ControlRight",
  "AltLeft", "AltRight",
  "ShiftLeft", "ShiftRight",
  "MetaLeft", "MetaRight",
]);

// ── Component ─────────────────────────────────────────────────────────────────

export function HotkeySetting() {
  const [accel, setAccel] = useState<string | null>(null);
  const [capturing, setCapturing] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const listenerRef = useRef<((e: KeyboardEvent) => void) | null>(null);

  // Load current hotkey on mount.
  useEffect(() => {
    getHotkey()
      .then(setAccel)
      .catch(() => setAccel("control+alt+KeyD"));
  }, []);

  // Attach/detach capture listener when `capturing` changes.
  useEffect(() => {
    if (!capturing) {
      if (listenerRef.current) {
        window.removeEventListener("keydown", listenerRef.current);
        listenerRef.current = null;
      }
      return;
    }

    const handler = async (e: KeyboardEvent) => {
      e.preventDefault();

      // Ignore pure modifier presses.
      if (PURE_MODIFIER_CODES.has(e.code)) return;

      // Esc cancels capture.
      if (e.code === "Escape" && !e.ctrlKey && !e.altKey && !e.shiftKey && !e.metaKey) {
        setCapturing(false);
        setErrorMsg(null);
        return;
      }

      const newAccel = buildAccelerator(e);
      if (!newAccel) {
        setErrorMsg("Use at least one modifier (⌘/⌃/⌥/⇧)");
        return;
      }

      try {
        await setHotkey(newAccel);
        setAccel(newAccel);
        setCapturing(false);
        setErrorMsg(null);
      } catch (err) {
        const msg =
          typeof err === "string"
            ? err
            : err instanceof Error
            ? err.message
            : "Failed to set shortcut.";
        setErrorMsg(msg);
        // Stay in capture mode so the user can try another combo.
      }
    };

    listenerRef.current = handler;
    window.addEventListener("keydown", handler);

    return () => {
      window.removeEventListener("keydown", handler);
      listenerRef.current = null;
    };
  }, [capturing]);

  const displayLabel = accel ? formatAccelerator(accel) : "…";

  return (
    <div className="flex items-center justify-between px-4 py-2">
      <span className="text-sm font-medium">Recording shortcut</span>
      <div className="flex items-center gap-3">
        {capturing ? (
          <span className="text-sm opacity-70 italic">
            Press a key combo… (Esc to cancel)
          </span>
        ) : (
          <kbd className="text-sm font-mono bg-muted px-2 py-0.5 rounded border">
            {displayLabel}
          </kbd>
        )}
        {errorMsg && (
          <span className="text-xs text-destructive">{errorMsg}</span>
        )}
        {!capturing && (
          <button
            className="text-xs underline opacity-70 hover:opacity-100"
            onClick={() => {
              setErrorMsg(null);
              setCapturing(true);
            }}
          >
            Change
          </button>
        )}
      </div>
    </div>
  );
}
