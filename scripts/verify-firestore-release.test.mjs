import { test } from 'node:test';
import assert from 'node:assert/strict';
import { captureRelease, selectFirebaseAccount, sha256, validateTarget } from './verify-firestore-release.mjs';

test('requires explicit account selection when cached Firebase logins are ambiguous', () => {
  const result = [{ user: { email: 'a@example.test' } }, { user: { email: 'b@example.test' } }];
  assert.throws(() => selectFirebaseAccount({ status: 'success', result }), /unambiguous/);
  assert.equal(selectFirebaseAccount({ status: 'success', result }, 'b@example.test'), result[1]);
  assert.throws(() => selectFirebaseAccount({ status: 'success', result }, 'missing@example.test'), /unambiguous/);
  assert.throws(() => selectFirebaseAccount({ status: 'error', result }), /unambiguous/);
});

const target = { projectId: 'augmentmereality', projectNumber: '895624785272', databaseId: '(default)' };
const name = 'projects/augmentmereality/releases/cloud.firestore';
const release = { name, rulesetName: 'projects/augmentmereality/rulesets/test-rules', updateTime: '2026-09-08T00:00:00Z' };
const candidate = "rules_version = '2';\n";
function responder({ changed = false, foreign = false, appCheckFails = false, source = candidate } = {}) {
  let releaseReads = 0;
  return async url => {
    if (url.endsWith('/releases/cloud.firestore')) {
      releaseReads++;
      return { ...release, ...(changed && releaseReads > 1 ? { rulesetName: 'projects/augmentmereality/rulesets/new-rules' } : {}) };
    }
    if (url.includes('/rulesets/')) return { name: foreign ? 'projects/another-project/rulesets/test-rules' : release.rulesetName,
      source: { files: [{ name: '../../not-a-local-path.rules', content: source }] } };
    if (appCheckFails) throw new Error('Sensitive remote error must not reach output');
    return { name: 'projects/895624785272/services/firestore.googleapis.com', token: 'must-not-serialize' };
  };
}
test('captures exact source hashes with safe local names and reports omitted App Check mode as unknown', async () => {
  const result = await captureRelease({ target, candidate, get: responder() });
  assert.equal(result.evidence.candidate.matchesActiveSource, true);
  assert.equal(result.evidence.sourceFiles[0].sha256, sha256(candidate));
  assert.equal(result.files[0].savedAs, 'active-0.rules');
  assert.equal(result.evidence.appCheck.enforcementMode, 'NOT_RETURNED');
  assert.equal(JSON.stringify(result.evidence).includes('must-not-serialize'), false);
});
test('rejects a deployment changing between metadata and source retrieval', async () => {
  await assert.rejects(captureRelease({ target, candidate, get: responder({ changed: true }) }), /changed during/);
});
test('rejects source belonging to a different project', async () => {
  await assert.rejects(captureRelease({ target, candidate, get: responder({ foreign: true }) }), /mismatched/);
});
test('does not call an arbitrary project or named database', async () => {
  await assert.rejects(captureRelease({ target: { ...target, projectId: '../other' }, candidate, get: () => assert.fail() }), /Invalid/);
  await assert.rejects(captureRelease({ target: { ...target, databaseId: 'other' }, candidate, get: () => assert.fail() }), /Invalid/);
});
test('validates target independently before acquiring credentials', () => {
  assert.doesNotThrow(() => validateTarget(target));
  for (const invalid of [null, {}, { ...target, projectId: '../other' },
    { ...target, projectNumber: 'not-a-project-number' }, { ...target, databaseId: 'other' }]) {
    assert.throws(() => validateTarget(invalid), /Invalid explicit Firestore target/);
  }
});
test('rejects ruleset paths with extra or traversal segments before requesting source', async () => {
  for (const suffix of ['test-rules/extra', 'test-rules/../foreign', '../foreign', 'test-rules/']) {
    let calls = 0;
    await assert.rejects(captureRelease({ target, candidate, get: async url => {
      calls++;
      assert.equal(url, `https://firebaserules.googleapis.com/v1/${name}`);
      return { ...release, rulesetName: `projects/${target.projectId}/rulesets/${suffix}` };
    } }), /Release identity/);
    assert.equal(calls, 1, 'Malformed source references must not trigger another metadata request');
  }
});
test('candidate mismatch is preserved as evidence instead of declaring deployment success', async () => {
  const result = await captureRelease({ target, candidate, get: responder({ source: 'different active rules' }) });
  assert.equal(result.evidence.candidate.matchesActiveSource, false);
});
test('unavailable App Check evidence cannot become an enforcement claim or leak errors', async () => {
  const result = await captureRelease({ target, candidate, get: responder({ appCheckFails: true }) });
  assert.equal(result.evidence.appCheck.enforcementMode, 'UNKNOWN');
  assert.equal(JSON.stringify(result.evidence).includes('Sensitive'), false);
});
