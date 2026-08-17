// Round 8 (counsel B5/seam-3/ux-2/flows-3): the reaction emoji allow-list in
// firestore.rules must equal the list the shipping reaction bar offers —
// verbatim. The round-6 draft denied 😂 (offered by the UI, 25% of every
// reaction tap) and permitted 🎉/😭 (never sent). This check parses BOTH
// sources and fails the suite on any drift; the emulator tests then reuse the
// app's list so every offered emoji is proven writable.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));

export function appEmojiList() {
  const swift = readFileSync(
    join(here, '..', '..', 'AugmentMeReality', 'Sharing', 'ReactionSession.swift'),
    'utf8'
  );
  const match = swift.match(/static let reactions = \[([^\]]*)\]/);
  if (!match) throw new Error('ReactionSession.reactions not found — update drift-check.mjs');
  return [...match[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
}

export function rulesEmojiList() {
  const rules = readFileSync(join(here, '..', 'firestore.rules'), 'utf8');
  const match = rules.match(/data\.emoji in \[([^\]]*)\]/);
  if (!match) throw new Error('emoji allow-list not found in firestore.rules — update drift-check.mjs');
  return [...match[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
}

// Round 12 (counsel SEAMS-lens-5): the rules' hasOnly key list must equal the
// fields DropReaction actually encodes — adding a field to the struct without
// touching the rules turns EVERY reaction write into permission-denied, which
// the client now (correctly) escalates to a terminal verdict.
export function appReactionKeys() {
  const swift = readFileSync(
    join(here, '..', '..', 'AugmentMeReality', 'Services', 'ReactionService.swift'),
    'utf8'
  );
  const structMatch = swift.match(/struct DropReaction[^{]*\{([\s\S]*?)\n\}/);
  if (!structMatch) throw new Error('DropReaction struct not found — update drift-check.mjs');
  // Round 14 (counsel seams-4): FAIL-CLOSED parsing — matches `var`/`let`,
  // optional property-wrapper/attribute prefixes, and sanity-checks the
  // count: a lock that silently parses zero fields protects nothing.
  const keys = [
    ...structMatch[1].matchAll(
      /^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:var|let)\s+(\w+)\s*[:=]/gm
    ),
  ].map((m) => m[1]);
  if (keys.length < 3) {
    throw new Error(
      `DropReaction parse suspicious (${keys.length} fields) — the drift lock regex needs updating, refusing to pass`
    );
  }
  return keys;
}

export function rulesReactionKeys() {
  const rules = readFileSync(join(here, '..', 'firestore.rules'), 'utf8');
  const match = rules.match(/keys\(\)\.hasOnly\(\[([^\]]*)\]\)/);
  if (!match) throw new Error('reaction key allow-list not found in firestore.rules — update drift-check.mjs');
  return [...match[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const app = appEmojiList();
  const rules = rulesEmojiList();
  const emojiSame =
    app.length === rules.length && app.every((emoji) => rules.includes(emoji));
  if (!emojiSame) {
    console.error('EMOJI DRIFT between ReactionSession.swift and firestore.rules');
    console.error('  app  :', app.join(' '));
    console.error('  rules:', rules.join(' '));
    process.exit(1);
  }
  console.log('emoji drift check OK:', app.join(' '));

  const appKeys = appReactionKeys();
  const ruleKeys = rulesReactionKeys();
  const keysSame =
    appKeys.length === ruleKeys.length && appKeys.every((k) => ruleKeys.includes(k));
  if (!keysSame) {
    console.error('REACTION KEY DRIFT between DropReaction and firestore.rules hasOnly');
    console.error('  app  :', appKeys.join(', '));
    console.error('  rules:', ruleKeys.join(', '));
    process.exit(1);
  }
  console.log('reaction key drift check OK:', appKeys.join(', '));
}
