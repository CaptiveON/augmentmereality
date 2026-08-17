// Round 8 (counsel B5, PBS-10): emulator verification of firestore.rules v3.
// One assertion per behavior the CLIENT depends on — including every error
// path the client maps to a verdict (permission-denied → refusedByServer
// terminal; absent-doc get answering → tombstone retirement + fetchSharedDrop).
// Run via `npm test` (drift check first, then emulators:exec wraps this file).
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from '@firebase/rules-unit-testing';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import {
  doc, getDoc, setDoc, updateDoc, deleteDoc, collection, query, where, getDocs,
  orderBy, limit,
} from 'firebase/firestore';
import { appEmojiList, appReactionKeys } from './drift-check.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const rules = readFileSync(join(here, '..', 'firestore.rules'), 'utf8');

const env = await initializeTestEnvironment({
  projectId: 'demo-amr-rules',
  firestore: { rules },
});

const OWNER = 'owner-uid';
const STRANGER = 'stranger-uid';
const owner = env.authenticatedContext(OWNER).firestore();
const stranger = env.authenticatedContext(STRANGER).firestore();
const anonymousViewer = env.unauthenticatedContext().firestore();

const dropData = (uid, visibility) => ({
  ownerUid: uid,
  geohash: 'u4pruydq',
  visibility,
  drop: { id: 'seed', message: 'hi', visibility },
});

// Seed data outside the rules.
await env.withSecurityRulesDisabled(async (context) => {
  const db = context.firestore();
  await setDoc(doc(db, 'drops/private-drop'), dropData(OWNER, 'private'));
  await setDoc(doc(db, 'drops/link-drop'), dropData(OWNER, 'link'));
});

let failures = 0;
async function check(name, promise) {
  try {
    await promise;
    console.log('  ok –', name);
  } catch (error) {
    failures += 1;
    console.error('  FAIL –', name, '\n    ', String(error).split('\n')[0]);
  }
}

console.log('drops · get/list');
// B5 correction: GET on a MISSING doc must ANSWER (exists=false), not deny —
// fetchSharedDrop's `exists` check and the tombstone retirement probe
// (serverConfirmsAbsent) both read absent documents on purpose.
await check('get missing doc answers for signed-in user',
  assertSucceeds(getDoc(doc(stranger, 'drops/never-existed'))));
await check('get missing doc denied for signed-out user',
  assertFails(getDoc(doc(anonymousViewer, 'drops/never-existed'))));
await check('owner gets own private drop',
  assertSucceeds(getDoc(doc(owner, 'drops/private-drop'))));
await check('stranger denied another user\'s private drop',
  assertFails(getDoc(doc(stranger, 'drops/private-drop'))));
await check('stranger gets link-visible drop by exact id (magic link)',
  assertSucceeds(getDoc(doc(stranger, 'drops/link-drop'))));
await check('owner-scoped list allowed',
  assertSucceeds(getDocs(query(collection(owner, 'drops'), where('ownerUid', '==', OWNER)))));
await check('unscoped list denied (no enumeration of shared drops)',
  assertFails(getDocs(collection(stranger, 'drops'))));

console.log('drops · create/update/delete');
await check('create with own ownerUid allowed',
  assertSucceeds(setDoc(doc(owner, 'drops/new-own'), dropData(OWNER, 'private'))));
await check('create stamped with a FOREIGN ownerUid denied',
  assertFails(setDoc(doc(stranger, 'drops/forged'), dropData(OWNER, 'private'))));
// permission-denied here is what the client maps to refusedByServer (B1).
await check('update by non-owner denied (hijack blocked; terminal-verdict code)',
  assertFails(updateDoc(doc(stranger, 'drops/link-drop'), { visibility: 'public' })));
await check('update by owner allowed',
  assertSucceeds(updateDoc(doc(owner, 'drops/link-drop'), { visibility: 'link' })));
await check('update reassigning ownerUid denied (immutable)',
  assertFails(updateDoc(doc(owner, 'drops/link-drop'), { ownerUid: STRANGER })));
await check('delete of ABSENT doc succeeds (tombstone pipeline)',
  assertSucceeds(deleteDoc(doc(owner, 'drops/never-existed'))));
await check('delete of another user\'s doc denied',
  assertFails(deleteDoc(doc(stranger, 'drops/private-drop'))));

console.log('reactions (capability model: dropId UUID is the secret)');
// Round 14 (counsel own-2): the emulator payload is DERIVED from the app's
// actual DropReaction fields — if the struct grows a field, this suite
// writes what the app will write and fails the moment the rules refuse it.
const sampleValues = {
  id: 'r1', emoji: '❤️', uid: 'placeholder', byName: 'Tester', at: new Date(),
};
const reaction = (uid, emoji, extra = {}) => {
  const payload = {};
  for (const key of appReactionKeys()) {
    if (!(key in sampleValues)) {
      throw new Error(`DropReaction gained field '${key}' with no sample value — update rules + drift lock + this map together`);
    }
    payload[key] = sampleValues[key];
  }
  payload.uid = uid;
  payload.emoji = emoji;
  return { ...payload, ...extra };
};
for (const emoji of appEmojiList()) {
  await check(`every UI emoji writable: ${emoji}`,
    assertSucceeds(setDoc(
      doc(stranger, `drops/link-drop/reactions/ok-${Math.random().toString(36).slice(2)}`),
      reaction(STRANGER, emoji)
    )));
}
await check('emoji outside the UI list denied (🎉)',
  assertFails(setDoc(doc(stranger, 'drops/link-drop/reactions/bad-emoji'),
    reaction(STRANGER, '🎉'))));
await check('reaction with forged author uid denied',
  assertFails(setDoc(doc(stranger, 'drops/link-drop/reactions/forged'),
    reaction(OWNER, '❤️'))));
await check('reaction with extra keys denied',
  assertFails(setDoc(doc(stranger, 'drops/link-drop/reactions/extra'),
    reaction(STRANGER, '❤️', { sneaky: true }))));
// B5 correction: no parent-visibility get() on create — a reaction to a drop
// whose upload hasn't flushed yet (offline share) must not be refused.
await check('reaction under a not-yet-uploaded drop allowed (offline share)',
  assertSucceeds(setDoc(doc(stranger, 'drops/not-yet-uploaded/reactions/early'),
    reaction(STRANGER, '❤️'))));
await check('reaction author may delete own reaction',
  assertSucceeds((async () => {
    await setDoc(doc(stranger, 'drops/link-drop/reactions/mine'),
      reaction(STRANGER, '❤️'));
    await deleteDoc(doc(stranger, 'drops/link-drop/reactions/mine'));
  })()));
await check('drop owner may delete any reaction on their drop (moderation)',
  assertSucceeds((async () => {
    await setDoc(doc(stranger, 'drops/link-drop/reactions/theirs'),
      reaction(STRANGER, '🤯'));
    await deleteDoc(doc(owner, 'drops/link-drop/reactions/theirs'));
  })()));
await check('stranger may NOT delete another author\'s reaction',
  assertFails((async () => {
    await setDoc(doc(stranger, 'drops/link-drop/reactions/protected'),
      reaction(STRANGER, '🥹'));
    const otherViewer = env.authenticatedContext('third-uid').firestore();
    await deleteDoc(doc(otherViewer, 'drops/link-drop/reactions/protected'));
  })()));
await check('reaction update denied (immutable log)',
  assertFails((async () => {
    await setDoc(doc(stranger, 'drops/link-drop/reactions/frozen'),
      reaction(STRANGER, '❤️'));
    await updateDoc(doc(stranger, 'drops/link-drop/reactions/frozen'),
      { emoji: '🤯' });
  })()));

console.log('client read shapes (round 10, counsel seams-8)');
// The sender-side toast listener issues exactly this query (order+limit on
// the subcollection = a LIST operation) — assert the shape, not a plain get.
await check('reactions LIST via order+limit (the sender listener query shape)',
  assertSucceeds(getDocs(query(
    collection(owner, 'drops/link-drop/reactions'),
    orderBy('at', 'desc'), limit(1)
  ))));
// Profile seeding keys on a SERVER-CONFIRMED absence of users/{uid} — the
// absent-doc get must answer, not deny (rule never touches resource).
await check('own ABSENT user doc answers (profile seeding depends on it)',
  assertSucceeds(getDoc(doc(
    env.authenticatedContext('fresh-uid').firestore(), 'users/fresh-uid'
  ))));

console.log('users');
await check('own user doc writable',
  assertSucceeds(setDoc(doc(owner, `users/${OWNER}`), { displayName: 'Me' })));
await check('foreign user doc read denied',
  assertFails(getDoc(doc(stranger, `users/${OWNER}`))));

await env.cleanup();
if (failures > 0) {
  console.error(`\n${failures} rules assertion(s) FAILED`);
  process.exit(1);
}
console.log('\nall rules assertions passed');
