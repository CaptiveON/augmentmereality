// Round 10 (counsel seams-1a): pins the PRODUCTION (v2) ruleset's behaviors —
// specifically the denials the client code must survive until the v3 deploy.
// If any of these assertions starts failing, either production was redeployed
// (update web/firestore.rules.deployed to match) or the client's assumptions
// about the live backend are wrong — both must be looked at, never ignored.
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from '@firebase/rules-unit-testing';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import {
  doc, getDoc, setDoc, deleteDoc, collection, query, where, getDocs,
} from 'firebase/firestore';

const here = dirname(fileURLToPath(import.meta.url));
const rules = readFileSync(join(here, '..', 'firestore.rules.deployed'), 'utf8');

const env = await initializeTestEnvironment({
  projectId: 'demo-amr-rules-deployed',
  firestore: { rules },
});

const OWNER = 'owner-uid';
const owner = env.authenticatedContext(OWNER).firestore();
const stranger = env.authenticatedContext('stranger-uid').firestore();

await env.withSecurityRulesDisabled(async (context) => {
  await setDoc(doc(context.firestore(), 'drops/link-drop'), {
    ownerUid: OWNER, visibility: 'link', drop: { id: 'seed' },
  });
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

console.log('deployed v2 — the denials the client must survive');
// serverConfirmsAbsent can NEVER answer under v2: absent-doc get denies.
// This is why probeAbsenceCapability exists and why tombstone retirement is
// capability-gated (DropStore.swift round 10).
await check('absent-doc GET denies (capability probe must report .denied)',
  assertFails(getDoc(doc(owner, 'drops/never-existed'))));
// Deletes of absent docs deny — never-acked deletes must resolve client-side
// via ackedCloudIDs, not wait for a server answer (DropStore round 10).
await check('absent-doc DELETE denies (never-acked deletes resolve client-side)',
  assertFails(deleteDoc(doc(owner, 'drops/never-existed'))));
// Reads that DO work under v2 (the app functions today):
await check('owner reads own drop', assertSucceeds(getDoc(doc(owner, 'drops/link-drop'))));
await check('stranger reads link drop (magic link works)',
  assertSucceeds(getDoc(doc(stranger, 'drops/link-drop'))));
// Round 14 (counsel seams-6): the refresh query shape the client issues
// every pass must be allowed by the LIVE rules too.
await check('owner-scoped LIST allowed under v2 (the refresh query shape)',
  assertSucceeds(getDocs(query(collection(owner, 'drops'), where('ownerUid', '==', OWNER)))));
// The v2 defect v3 exists to fix — pinned so its disappearance (a redeploy)
// is noticed: update only validates the INCOMING ownerUid.
await check('v2 DEFECT still present: stranger can hijack via update stamping own uid',
  assertSucceeds(setDoc(doc(stranger, 'drops/link-drop'), {
    ownerUid: 'stranger-uid', visibility: 'link', drop: { id: 'seed' },
  })));

await env.cleanup();
if (failures > 0) {
  console.error(`\n${failures} deployed-rules assertion(s) FAILED`);
  process.exit(1);
}
console.log('\ndeployed-rules assertions all passed');
