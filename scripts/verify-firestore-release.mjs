// Read-only release verification. Credentials stay in memory and never enter output.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { resolve, dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const sha256 = text => createHash('sha256').update(text, 'utf8').digest('hex');

export function selectFirebaseAccount(response, email) {
  const accounts = response?.status === 'success' && Array.isArray(response.result) ? response.result : [];
  const selected = email ? accounts.filter(account => account.user?.email === email) : accounts;
  if (selected.length !== 1 || !selected[0].user?.email) {
    throw new Error('Could not obtain an unambiguous Firebase account. Run firebase login, or select --account EMAIL.');
  }
  return selected[0];
}

async function accessToken({ projectId, auth, account }) {
  // Firebase's JSON account listing includes credentials. Capture it only in memory;
  // never print subprocess output, even on errors. Disable inherited debug logging.
  const env = { ...process.env };
  delete env.DEBUG;
  delete env.FIREBASE_TOKEN;
  const cwd = await mkdtemp(join(tmpdir(), 'amr-rules-auth-'));
  const run = (command, args) => execFileSync(command, args,
    { cwd, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 30000 });
  try {
    if (auth === 'gcloud') return run('gcloud', ['auth', 'print-access-token', '--project', projectId,
      ...(account ? ['--account', account] : [])]).trim();
    const selected = selectFirebaseAccount(JSON.parse(run('firebase', ['login:list', '--json'])), account);
    // This read-only command refreshes the chosen CLI account if necessary. Passing
    // --account and --project avoids changing global defaults or selecting another app.
    run('firebase', ['apps:list', 'IOS', '--project', projectId, '--account', selected.user.email,
      '--non-interactive', '--json']);
    return selectFirebaseAccount(JSON.parse(run('firebase', ['login:list', '--json'])),
      selected.user.email).tokens?.access_token;
  } catch {
    throw new Error('Could not obtain OAuth credentials. Authenticate the intended account or select --auth/--account; subprocess output is suppressed.');
  } finally {
    await rm(cwd, { recursive: true, force: true });
  }
}

export function validateTarget(target) {
  const { projectId, projectNumber, databaseId } = target ?? {};
  if (!/^[a-z][a-z0-9-]{4,28}[a-z0-9]$/.test(projectId ?? '')
      || !/^\d+$/.test(projectNumber ?? '') || databaseId !== '(default)') {
    throw new Error('Invalid explicit Firestore target; this verifier supports the default database only.');
  }
}

export async function captureRelease({ target, candidate, get, checkedAt = new Date().toISOString() }) {
  validateTarget(target);
  const { projectId, projectNumber } = target;
  const name = `projects/${projectId}/releases/cloud.firestore`;
  const releaseURL = `https://firebaserules.googleapis.com/v1/${name}`;
  const release = await get(releaseURL);
  if (release?.name !== name
      || !new RegExp(`^projects/${projectId}/rulesets/[a-zA-Z0-9-]+$`).test(release.rulesetName ?? '')) {
    throw new Error('Release identity does not match the explicit project.');
  }
  const ruleset = await get(`https://firebaserules.googleapis.com/v1/${release.rulesetName}`);
  if (ruleset.name !== release.rulesetName || !Array.isArray(ruleset.source?.files)
      || ruleset.source.files.length === 0) throw new Error('Missing or mismatched ruleset source.');
  const files = ruleset.source.files.map((file, index) => {
    if (typeof file.name !== 'string' || typeof file.content !== 'string') {
      throw new Error('Invalid source file in ruleset response.');
    }
    return { name: file.name, savedAs: `active-${index}.rules`, content: file.content,
      sha256: sha256(file.content), bytes: Buffer.byteLength(file.content, 'utf8') };
  });
  // Do not combine source from one deployment with metadata from a newer deployment.
  const after = await get(releaseURL);
  if (after.name !== release.name || after.rulesetName !== release.rulesetName
      || after.updateTime !== release.updateTime) {
    throw new Error('Active release changed during verification; retry for coherent evidence.');
  }
  let appCheck;
  try {
    const serviceName = `projects/${projectNumber}/services/firestore.googleapis.com`;
    const service = await get(`https://firebaseappcheck.googleapis.com/v1/${serviceName}`);
    if (service.name !== serviceName) throw new Error('Unexpected App Check service identity.');
    appCheck = { name: serviceName, verification: 'read',
      enforcementMode: service.enforcementMode ?? 'NOT_RETURNED',
      updateTime: service.updateTime ?? null,
      note: service.enforcementMode ? 'No enforcement changes made.' : 'API omitted the mode; enforcement is not inferred.' };
  } catch {
    appCheck = { verification: 'unavailable', enforcementMode: 'UNKNOWN',
      note: 'Read failed; no enforcement changes made.' };
  }
  return {
    evidence: { schemaVersion: 1, checkedAt, target,
      method: 'Read-only Rules REST release + referenced source + repeat release check; no user-document reads.',
      release: { name: release.name, rulesetName: release.rulesetName,
        createTime: release.createTime ?? null, updateTime: release.updateTime ?? null },
      rulesetCreatedAt: ruleset.createTime ?? null,
      sourceFiles: files.map(({ content, ...metadata }) => metadata),
      candidate: { path: 'web/firestore.rules', sha256: sha256(candidate),
        matchesActiveSource: files.length === 1 && files[0].content === candidate },
      appCheck },
    files
  };
}

async function main() {
  const args = process.argv.slice(2);
  let output, expectCandidate = false, auth = 'firebase', account;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--output' && args[i + 1]) output = resolve(args[++i]);
    else if (args[i] === '--expect-candidate') expectCandidate = true;
    else if (args[i] === '--auth' && ['firebase', 'gcloud'].includes(args[i + 1])) auth = args[++i];
    else if (args[i] === '--account' && args[i + 1]) account = args[++i];
    else throw new Error('Usage: node scripts/verify-firestore-release.mjs --output NEW_DIRECTORY [--expect-candidate] [--auth firebase|gcloud] [--account EMAIL]');
  }
  if (!output) throw new Error('A new output directory is required; historical evidence is never overwritten.');
  const target = JSON.parse(await readFile(join(root, 'web/firestore-target.json'), 'utf8'));
  // Reject a malformed target before any credential refresh or CLI API request.
  validateTarget(target);
  const candidate = await readFile(join(root, 'web/firestore.rules'), 'utf8');
  const token = await accessToken({ projectId: target.projectId, auth, account });
  if (!token || /\s/.test(token)) throw new Error('Invalid OAuth credential response.');
  const get = async url => {
    const response = await fetch(url, { method: 'GET',
      headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(20000), redirect: 'error' });
    if (!response.ok) throw new Error(`Read-only metadata request failed (HTTP ${response.status}).`);
    return response.json();
  };
  const result = await captureRelease({ target, candidate, get });
  // Non-recursive creation intentionally fails if this evidence directory already exists.
  await mkdir(output, { mode: 0o700 });
  for (const file of result.files) await writeFile(join(output, file.savedAs), file.content, { mode: 0o600, flag: 'wx' });
  await writeFile(join(output, 'release.json'), JSON.stringify(result.evidence, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
  console.log(JSON.stringify({ output, ...result.evidence }, null, 2));
  if (expectCandidate && !result.evidence.candidate.matchesActiveSource) process.exitCode = 2;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => {
    // Do not print raw SDK responses, subprocess output, headers, tokens or stacks.
    const known = /^(Invalid |Missing |Release identity|Active release changed|Usage:|A new output|Could not obtain|Read-only metadata)/.test(error.message);
    console.error(known ? error.message : 'Release verification failed; no deployment was performed. Check authentication, connectivity and the new output directory.');
    process.exitCode = 1;
  });
}
