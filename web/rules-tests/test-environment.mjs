import { initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { readFileSync } from 'node:fs';

// Both suites run sequentially against this disposable emulator project. A
// checked-in fixture is never evidence of the rules deployed to a real project.
// npm test uses --test-force-exit because the SDK retains process-level timers
// after awaited client termination. Test/hook timeouts and failures still fail
// the runner; these authorization tests do not assert a native lifecycle claim.
export async function createRulesEnvironment(rulesPath) {
  const endpoint = process.env.FIRESTORE_EMULATOR_HOST;
  const match = endpoint?.match(/^(localhost|127\.0\.0\.1|\[::1\]):(\d+)$/);
  if (!match || Number(match[2]) < 1 || Number(match[2]) > 65535) {
    throw new Error('Rules tests require FIRESTORE_EMULATOR_HOST on loopback; run npm test.');
  }
  const env = await initializeTestEnvironment({
    projectId: 'demo-amr-rules',
    firestore: {
      host: match[1].replace(/^\[|\]$/g, ''),
      port: Number(match[2]),
      rules: readFileSync(rulesPath, 'utf8'),
    },
  });
  try {
    await env.clearFirestore();
    const clients = [];
    return {
      env,
      firestore(uid) {
        const context = uid === undefined
          ? env.unauthenticatedContext()
          : env.authenticatedContext(uid);
        const db = context.firestore();
        clients.push(db);
        return db;
      },
      async cleanup() {
        try {
          // rules-unit-testing 4.x invokes app.delete() without awaiting it.
          // Wait for SDK streams/retry timers to stop before the runner exits.
          await Promise.all(clients.map((db) => db.terminate()));
        } finally {
          await env.cleanup();
        }
      },
    };
  } catch (error) {
    await env.cleanup();
    throw error;
  }
}
