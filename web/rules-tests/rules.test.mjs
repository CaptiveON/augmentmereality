// Tests the reviewed local web/firestore.rules in a disposable emulator.
// Passing these tests says nothing about a real project's deployed release.
import assert from 'node:assert/strict';
import test, { after, describe } from 'node:test';
import { randomUUID } from 'node:crypto';
import { assertSucceeds, assertFails } from '@firebase/rules-unit-testing';
import {
  doc, getDocFromServer, getDocFromCache, setDoc, updateDoc, deleteDoc,
  deleteField, collection, query, where, getDocs, orderBy, documentId, limit, startAfter, Timestamp,
  disableNetwork, enableNetwork, runTransaction,
} from 'firebase/firestore';
import { appEmojiList, appReactionKeys } from './drift-check.mjs';
import { createRulesEnvironment } from './test-environment.mjs';

describe('reviewed local rules', { timeout: 60_000 }, async () => {
  const { env, firestore, cleanup } = await createRulesEnvironment(new URL('../firestore.rules', import.meta.url));
  after(() => cleanup(), { timeout: 15_000 });
  const check = (name, body) => test(name, { timeout: 15_000 }, body);
  const OWNER = 'owner-uid';
  const STRANGER = 'stranger-uid';
  const owner = firestore(OWNER);
  const stranger = firestore(STRANGER);
  const signedOut = firestore();
  const dropData = (uid, visibility = 'private') => ({
    ownerUid: uid, geohash: 'u4pruydq', visibility,
    drop: { id: 'seed', message: 'hi', visibility },
  });

  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    try {
      for (const visibility of ['private', 'link', 'public']) {
        await setDoc(doc(db, `drops/${visibility}-drop`), dropData(OWNER, visibility));
      }
      await setDoc(doc(db, 'drops/other-owned'), dropData(STRANGER));
    } finally {
      await db.terminate();
    }
  });

  for (const [label, db] of [['owner', owner], ['other signed-in account', stranger]]) {
    check(`drops GET: absent document answers exists=false for ${label}`, async () => {
      const snapshot = await assertSucceeds(getDocFromServer(doc(db, 'drops/never-existed')));
      assert.equal(snapshot.exists(), false);
      assert.equal(snapshot.metadata.fromCache, false);
    });
    check(`drops DELETE: absent document is an acknowledged no-op for ${label}`, async () => {
      await assertSucceeds(deleteDoc(doc(db, 'drops/never-existed')));
      assert.equal((await getDocFromServer(doc(db, 'drops/never-existed'))).exists(), false);
    });
  }
  check('drops GET: signed-out absent read is denied', async () => {
    await assertFails(getDocFromServer(doc(signedOut, 'drops/never-existed')));
  });
  check('drops DELETE: signed-out absent delete is denied', async () => {
    await assertFails(deleteDoc(doc(signedOut, 'drops/never-existed')));
  });
  for (const visibility of ['private', 'link', 'public']) {
    check(`drops GET: owner can read ${visibility}; signed-out client cannot`, async () => {
      await assertSucceeds(getDocFromServer(doc(owner, `drops/${visibility}-drop`)));
      await assertFails(getDocFromServer(doc(signedOut, `drops/${visibility}-drop`)));
    });
    check(`drops GET: exact-id stranger read is ${visibility === 'private' ? 'denied' : 'allowed'} for ${visibility}`, async () => {
      const operation = getDocFromServer(doc(stranger, `drops/${visibility}-drop`));
      await (visibility === 'private' ? assertFails(operation) : assertSucceeds(operation));
    });
  }
  for (const [name, db, id, exists] of [
    ['owner private drop', owner, 'private-drop', true],
    ['viewer link drop', stranger, 'link-drop', true],
    ['viewer public drop', stranger, 'public-drop', true],
    ['absent drop', stranger, 'never-existed', false],
  ]) {
    check(`drops read-only transaction: ${name} completes its verification commit`, async () => {
      const snapshot = await assertSucceeds(runTransaction(db, (transaction) =>
        transaction.get(doc(db, `drops/${id}`)), { maxAttempts: 1 }));
      assert.equal(snapshot.exists(), exists);
      if (exists) assert.equal(snapshot.data().ownerUid, OWNER);
    });
  }
  for (const [name, db, id] of [
    ['foreign private drop', stranger, 'private-drop'],
    ['signed-out shared drop', signedOut, 'link-drop'],
    ['signed-out absent drop', signedOut, 'never-existed'],
  ]) {
    check(`drops read-only transaction: ${name} is denied`, async () => {
      await assertFails(runTransaction(db, (transaction) =>
        transaction.get(doc(db, `drops/${id}`)), { maxAttempts: 1 }));
    });
  }
  check('drops LIST: owner-scoped client refresh returns only owned records', async () => {
    const snapshot = await assertSucceeds(getDocs(query(collection(owner, 'drops'), where('ownerUid', '==', OWNER))));
    assert.deepEqual(snapshot.docs.map((entry) => entry.id).sort(), ['link-drop', 'private-drop', 'public-drop']);
    assert.ok(snapshot.docs.every((entry) => entry.data().ownerUid === OWNER));
  });
  test('drops LIST: document-ID owner pages reach every row without foreign enumeration',
    { timeout: 60_000 }, async () => {
      const idFor = (index) => `00000000-0000-0000-0000-${index.toString(16).toUpperCase().padStart(12, '0')}`;
      await env.withSecurityRulesDisabled(async (context) => {
        const db = context.firestore();
        try {
          const fixtures = [
            ...Array.from({ length: 130 }, (_, index) => [idFor(index * 2), OWNER]),
            [idFor(31), STRANGER], [idFor(95), STRANGER],
          ];
          for (let offset = 0; offset < fixtures.length; offset += 16) {
            await Promise.all(fixtures.slice(offset, offset + 16).map(([id, uid]) =>
              setDoc(doc(db, `drops/${id}`), dropData(uid))));
          }
        } finally {
          await db.terminate();
        }
      });

      const base = query(collection(owner, 'drops'),
        where('ownerUid', '==', OWNER), orderBy(documentId()));
      const found = new Set();
      const pageSizes = [];
      let cursor;
      for (let pageNumber = 0; pageNumber < 5; pageNumber++) {
        const pageQuery = cursor === undefined
          ? query(base, limit(64))
          : query(base, startAfter(cursor), limit(64));
        const snapshot = await assertSucceeds(getDocs(pageQuery));
        pageSizes.push(snapshot.size);
        assert.ok(snapshot.size <= 64);
        for (const row of snapshot.docs) {
          assert.equal(row.data().ownerUid, OWNER);
          assert.equal(found.has(row.id), false, `repeated owner ID ${row.id}`);
          found.add(row.id);
        }
        if (snapshot.size < 64) break;
        cursor = snapshot.docs.at(-1).id;
      }
      assert.deepEqual(pageSizes, [64, 64, 5]);
      assert.equal(found.size, 133);
      assert.ok(found.has(idFor(0)) && found.has(idFor(258)));
      assert.equal(found.has(idFor(31)) || found.has(idFor(95)), false);

      await assertFails(getDocs(query(collection(stranger, 'drops'),
        where('ownerUid', '==', OWNER), orderBy(documentId()), limit(64))));
      await assertFails(getDocs(query(collection(owner, 'drops'),
        orderBy(documentId()), limit(64))));
    });
  for (const [name, build] of [
    ['unscoped', (db) => collection(db, 'drops')],
    ['limited but unscoped', (db) => query(collection(db, 'drops'), limit(1))],
    ['foreign owner', (db) => query(collection(db, 'drops'), where('ownerUid', '==', OWNER))],
    ['link visibility', (db) => query(collection(db, 'drops'), where('visibility', '==', 'link'))],
    ['public visibility', (db) => query(collection(db, 'drops'), where('visibility', '==', 'public'))],
  ]) {
    check(`drops LIST: stranger cannot enumerate through ${name} query`, async () => {
      await assertFails(getDocs(build(stranger)));
    });
  }
  check('drops LIST: signed-out owner-filtered query is denied', async () => {
    await assertFails(getDocs(query(collection(signedOut, 'drops'), where('ownerUid', '==', OWNER))));
  });

  check('drops CREATE: own envelope succeeds and is readable from the server', async () => {
    await assertSucceeds(setDoc(doc(owner, 'drops/new-own'), dropData(OWNER)));
    assert.equal((await getDocFromServer(doc(owner, 'drops/new-own'))).data().ownerUid, OWNER);
  });
  check('drops CREATE: foreign owner stamp is denied', async () => {
    await assertFails(setDoc(doc(stranger, 'drops/forged'), dropData(OWNER)));
  });
  check('drops CREATE: missing owner stamp is denied', async () => {
    const { ownerUid, ...withoutOwner } = dropData(OWNER);
    await assertFails(setDoc(doc(owner, 'drops/unstamped'), withoutOwner));
  });
  check('drops CREATE: signed-out write is denied', async () => {
    await assertFails(setDoc(doc(signedOut, 'drops/signed-out'), dropData(OWNER)));
  });
  check('drops UPDATE: foreign partial update is denied', async () => {
    await assertFails(updateDoc(doc(stranger, 'drops/link-drop'), { visibility: 'public' }));
  });
  check('drops UPDATE regression: full replacement cannot hijack by stamping the attacker uid', async () => {
    await assertFails(setDoc(doc(stranger, 'drops/link-drop'), dropData(STRANGER, 'public')));
    const snapshot = await getDocFromServer(doc(owner, 'drops/link-drop'));
    assert.equal(snapshot.data().ownerUid, OWNER);
    assert.equal(snapshot.data().visibility, 'link');
  });
  check('drops UPDATE: foreign merge overwrite is denied', async () => {
    await assertFails(setDoc(doc(stranger, 'drops/link-drop'), { ownerUid: STRANGER }, { merge: true }));
  });
  check('drops UPDATE: owner may replace the client envelope without changing ownership', async () => {
    await setDoc(doc(owner, 'drops/replace-own'), dropData(OWNER));
    await assertSucceeds(setDoc(doc(owner, 'drops/replace-own'), dropData(OWNER, 'link')));
    assert.equal((await getDocFromServer(doc(owner, 'drops/replace-own'))).data().visibility, 'link');
  });
  for (const [name, operation] of [
    ['partial reassignment', () => updateDoc(doc(owner, 'drops/link-drop'), { ownerUid: STRANGER })],
    ['full replacement reassignment', () => setDoc(doc(owner, 'drops/link-drop'), dropData(STRANGER, 'link'))],
    ['owner field deletion', () => updateDoc(doc(owner, 'drops/link-drop'), { ownerUid: deleteField() })],
  ]) {
    check(`drops UPDATE: ownership is immutable during ${name}`, async () => {
      await assertFails(operation());
      assert.equal((await getDocFromServer(doc(owner, 'drops/link-drop'))).data().ownerUid, OWNER);
    });
  }
  check('drops UPDATE: signed-out mutation is denied', async () => {
    await assertFails(updateDoc(doc(signedOut, 'drops/link-drop'), { visibility: 'private' }));
  });
  check('drops DELETE: foreign and signed-out deletion are denied', async () => {
    await assertFails(deleteDoc(doc(stranger, 'drops/private-drop')));
    await assertFails(deleteDoc(doc(signedOut, 'drops/private-drop')));
    assert.equal((await getDocFromServer(doc(owner, 'drops/private-drop'))).exists(), true);
  });
  check('drops DELETE: owner deletion answers absent on a subsequent server read', async () => {
    await setDoc(doc(owner, 'drops/delete-own'), dropData(OWNER));
    await assertSucceeds(deleteDoc(doc(owner, 'drops/delete-own')));
    assert.equal((await getDocFromServer(doc(owner, 'drops/delete-own'))).exists(), false);
  });

  // Firestore-compatible representation of the current synthesized Swift Codable
  // fields. drift-check.test.mjs verifies field types. This is not execution of
  // Swift's Firestore.Encoder or proof of iOS offline persistence durability.
  const reactionDate = new Date('2026-09-08T00:00:00.123Z');
  const reaction = (id, uid, emoji = '❤️', extra = {}) => {
    const sample = { id, uid, emoji, byName: 'Test viewer 👋', at: reactionDate };
    const payload = {};
    for (const key of appReactionKeys()) {
      if (!(key in sample)) throw new Error(`Missing reaction fixture value for ${key}; update the client/rules contract together`);
      payload[key] = sample[key];
    }
    return { ...payload, ...extra };
  };
  for (const emoji of appEmojiList()) {
    check(`reactions CREATE: UI emoji ${emoji} and encoded field types round-trip`, async () => {
      const id = randomUUID();
      await assertSucceeds(setDoc(doc(stranger, `drops/link-drop/reactions/${id}`), reaction(id, STRANGER, emoji)));
      const snapshot = await getDocFromServer(doc(owner, `drops/link-drop/reactions/${id}`));
      const stored = snapshot.data();
      assert.deepEqual(Object.keys(stored).sort(), appReactionKeys().sort());
      assert.equal(stored.id, snapshot.id);
      assert.equal(stored.uid, STRANGER);
      assert.equal(stored.emoji, emoji);
      assert.equal(stored.byName, 'Test viewer 👋');
      assert.ok(stored.at instanceof Timestamp);
      assert.equal(stored.at.toMillis(), reactionDate.getTime());
    });
  }
  for (const [name, db, payload] of [
    ['emoji outside the UI list', stranger, reaction('bad-emoji', STRANGER, '🎉')],
    ['forged author uid', stranger, reaction('forged-author', OWNER)],
    ['extra encoded field', stranger, reaction('extra', STRANGER, '❤️', { sneaky: true })],
    ['signed-out writer', signedOut, reaction('signed-out', STRANGER)],
  ]) {
    check(`reactions CREATE: ${name} is denied`, async () => {
      await assertFails(setDoc(doc(db, `drops/link-drop/reactions/${payload.id}`), payload));
    });
  }
  check('reactions CREATE: offline queued write is accepted before its parent uploads', async () => {
    const db = firestore('offline-viewer');
    const parent = 'offline-parent';
    const id = randomUUID();
    const ref = doc(db, `drops/${parent}/reactions/${id}`);
    await disableNetwork(db);
    let outcome;
    const pendingWrite = setDoc(ref, reaction(id, 'offline-viewer')).then(
      () => { outcome = 'acknowledged'; },
      (error) => { outcome = error; },
    );
    try {
      const local = await getDocFromCache(ref);
      assert.equal(local.exists(), true);
      assert.equal(local.metadata.hasPendingWrites, true);
      assert.equal(outcome, undefined);
      assert.equal((await getDocFromServer(doc(owner, `drops/${parent}`))).exists(), false);
      await enableNetwork(db);
      await pendingWrite;
      assert.equal(outcome, 'acknowledged');
      const remote = await getDocFromServer(ref);
      assert.equal(remote.metadata.hasPendingWrites, false);
      assert.equal(remote.data().uid, 'offline-viewer');
      assert.equal((await getDocFromServer(doc(owner, `drops/${parent}`))).exists(), false);
      await setDoc(doc(owner, `drops/${parent}`), dropData(OWNER, 'link'));
      assert.equal((await getDocFromServer(doc(owner, `drops/${parent}/reactions/${id}`))).exists(), true);
    } finally {
      await enableNetwork(db);
    }
  });
  check('reactions CREATE: a private parent does not block the existing UUID capability contract', async () => {
    await assertSucceeds(setDoc(doc(stranger, 'drops/private-drop/reactions/capability'), reaction('capability', STRANGER)));
  });
  check('reactions DELETE: author can remove their reaction with no parent document', async () => {
    const path = 'drops/missing-reaction-parent/reactions/mine';
    await setDoc(doc(stranger, path), reaction('mine', STRANGER));
    await assertSucceeds(deleteDoc(doc(stranger, path)));
  });
  check('reactions DELETE: parent owner can moderate another author', async () => {
    const path = 'drops/link-drop/reactions/moderated';
    await setDoc(doc(stranger, path), reaction('moderated', STRANGER));
    await assertSucceeds(deleteDoc(doc(owner, path)));
  });
  check('reactions DELETE: unrelated viewer cannot remove another author', async () => {
    const path = 'drops/link-drop/reactions/protected';
    await setDoc(doc(stranger, path), reaction('protected', STRANGER));
    const other = firestore('third-uid');
    await assertFails(deleteDoc(doc(other, path)));
    assert.equal((await getDocFromServer(doc(stranger, path))).exists(), true);
  });
  check('reactions UPDATE: neither author nor parent owner may rewrite the immutable log', async () => {
    const path = 'drops/link-drop/reactions/immutable';
    await setDoc(doc(stranger, path), reaction('immutable', STRANGER));
    await assertFails(updateDoc(doc(stranger, path), { emoji: '🤯' }));
    await assertFails(setDoc(doc(stranger, path), reaction('immutable', STRANGER, '😂')));
    await assertFails(updateDoc(doc(owner, path), { emoji: '🤯' }));
    assert.equal((await getDocFromServer(doc(stranger, path))).data().emoji, '❤️');
  });
  check('reactions READ: sender order/limit listener shape succeeds and signed-out reads fail', async () => {
    const snapshot = await assertSucceeds(getDocs(query(collection(owner, 'drops/link-drop/reactions'), orderBy('at', 'desc'), limit(1))));
    assert.equal(snapshot.size, 1);
    await assertFails(getDocs(query(collection(signedOut, 'drops/link-drop/reactions'), orderBy('at', 'desc'), limit(1))));
    await assertFails(getDocFromServer(doc(signedOut, 'drops/link-drop/reactions/immutable')));
  });

  check('users GET: own absent profile answers from server for profile seeding', async () => {
    const fresh = firestore('fresh-uid');
    const snapshot = await assertSucceeds(getDocFromServer(doc(fresh, 'users/fresh-uid')));
    assert.equal(snapshot.exists(), false);
    assert.equal(snapshot.metadata.fromCache, false);
  });
  check('users WRITE: owner can create, update, and delete their profile', async () => {
    const ref = doc(owner, `users/${OWNER}`);
    await assertSucceeds(setDoc(ref, { displayName: 'Me' }));
    await assertSucceeds(updateDoc(ref, { displayName: 'Updated' }));
    assert.equal((await getDocFromServer(ref)).data().displayName, 'Updated');
    await assertSucceeds(deleteDoc(ref));
  });
  check('users: foreign and signed-out clients cannot read or write an existing profile', async () => {
    await setDoc(doc(owner, `users/${OWNER}`), { displayName: 'Private profile' });
    for (const db of [stranger, signedOut]) {
      await assertFails(getDocFromServer(doc(db, `users/${OWNER}`)));
      await assertFails(setDoc(doc(db, `users/${OWNER}`), { displayName: 'Overwrite' }));
      await assertFails(deleteDoc(doc(db, `users/${OWNER}`)));
    }
  });
  check('users: foreign absent profile read is denied rather than disclosing existence', async () => {
    await assertFails(getDocFromServer(doc(stranger, 'users/not-my-uid')));
  });
});
