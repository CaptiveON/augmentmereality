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
export function parseAppReactionFields(swift) {
  const structMatch = swift.match(/struct DropReaction\b[^{]*\{([\s\S]*?)\n\}/);
  if (!structMatch) throw new Error('DropReaction struct not found — update drift-check.mjs');
  const body = structMatch[1];
  // This is a contract for today's synthesized Codable payload, not a Swift
  // encoder. Renaming CodingKeys, custom encoding, wrappers or computed fields
  // require explicit review; silently counting their property names is unsafe.
  if (/\bCodingKeys\b|\bfunc\s+encode\s*\(|@/.test(body) || /\bextension\s+DropReaction\b/.test(swift)) {
    throw new Error('DropReaction encoding customization requires an explicit drift-contract update');
  }
  const declarations = body.split('\n').filter((line) =>
    !line.trim().startsWith('//') && /\b(?:var|let)\s+\w+/.test(line));
  const fields = declarations.map((line) => {
    const match = line.match(/^\s*(?:var|let)\s+(\w+)\s*:\s*(\w+\??)(?:\s*=\s*[^{}]+)?\s*$/);
    if (!match) throw new Error(`Unsupported DropReaction field declaration: ${line.trim()}`);
    return { name: match[1], type: match[2] };
  });
  if (fields.length < 3) {
    throw new Error(
      `DropReaction parse suspicious (${fields.length} fields) — the drift lock needs updating, refusing to pass`
    );
  }
  return fields;
}

export function appReactionFields() {
  return parseAppReactionFields(readFileSync(
    join(here, '..', '..', 'AugmentMeReality', 'Services', 'ReactionService.swift'),
    'utf8'
  ));
}

export function appReactionKeys() {
  return appReactionFields().map(({ name }) => name);
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
