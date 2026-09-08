// Historical v2 regression fixture only. These emulator results describe the
// checked-in fixture; they cannot identify any currently deployed ruleset.
import assert from 'node:assert/strict';
import test, { after, describe } from 'node:test';
import { assertSucceeds, assertFails } from '@firebase/rules-unit-testing';
import { doc, getDocFromServer, setDoc, deleteDoc, collection, query, where, getDocs } from 'firebase/firestore';
import { createRulesEnvironment } from './test-environment.mjs';

describe('historical v2 fixture', { timeout: 60_000 }, async () => {
  const { env, firestore, cleanup } = await createRulesEnvironment(new URL('./fixtures/firestore.v2.rules', import.meta.url));
  after(() => cleanup(), { timeout: 15_000 });
  const OWNER = 'owner-uid';
  const STRANGER = 'stranger-uid';
  const owner = firestore(OWNER);
  const stranger = firestore(STRANGER);
  const data = (uid, visibility = 'link') => ({ ownerUid: uid, visibility, drop: { id: 'seed' } });

  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    try {
      for (const id of ['link-drop', 'hijack-drop']) {
        await setDoc(doc(db, `drops/${id}`), data(OWNER));
      }
    } finally {
      await db.terminate();
    }
  });

  test('historical v2: absent-document GET is denied', async () => {
    await assertFails(getDocFromServer(doc(owner, 'drops/never-existed')));
  });
  test('historical v2: absent-document DELETE is denied', async () => {
    await assertFails(deleteDoc(doc(owner, 'drops/never-existed')));
  });
  test('historical v2: owner and exact-link viewer can read the seeded drop', async () => {
    await assertSucceeds(getDocFromServer(doc(owner, 'drops/link-drop')));
    await assertSucceeds(getDocFromServer(doc(stranger, 'drops/link-drop')));
  });
  test('historical v2: owner-scoped refresh query is allowed', async () => {
    const snapshot = await assertSucceeds(getDocs(query(collection(owner, 'drops'), where('ownerUid', '==', OWNER))));
    assert.equal(snapshot.size, 2);
  });
  test('historical v2 regression: visibility-filtered LIST exposes another owner’s shared drop', async () => {
    const snapshot = await assertSucceeds(getDocs(query(collection(stranger, 'drops'), where('visibility', '==', 'link'))));
    assert.ok(snapshot.docs.some((entry) => entry.id === 'link-drop' && entry.data().ownerUid === OWNER));
  });
  test('historical v2 regression: full overwrite can hijack another owner’s drop', async () => {
    await assertSucceeds(setDoc(doc(stranger, 'drops/hijack-drop'), data(STRANGER)));
    const snapshot = await getDocFromServer(doc(stranger, 'drops/hijack-drop'));
    assert.equal(snapshot.data().ownerUid, STRANGER);
  });
});
