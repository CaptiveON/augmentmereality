// Invoke inside emulators:exec for demo-amr-native-sdk. The child is an explicit
// xcodebuild test-without-building command whose xctestrun opts into this probe.
// A loopback HTTP/2 proxy holds only Write RPCs, making a local unacknowledged
// delete deterministic while ordinary server reads and transactions still run.
import http from 'node:http';
import http2 from 'node:http2';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';

const project = 'demo-amr-native-sdk';
const backend = '127.0.0.1:8188';
if (process.env.FIRESTORE_EMULATOR_HOST !== backend ||
    (process.env.GCLOUD_PROJECT && process.env.GCLOUD_PROJECT !== project)) {
  throw new Error(`Requires the ${project} emulator at ${backend}`);
}
const command = process.argv.slice(2);
if (command[0] !== 'xcodebuild' || !command.includes('test-without-building')) {
  throw new Error('Pass an explicit xcodebuild test-without-building command');
}

let holdWrites = false;
let holdReads = false;
const held = new Set();
const upstreamSessions = new Set();
const incomingSessions = new Set();
const counters = { heldWrites: 0, heldReads: 0, readyRequests: 0, seedRequests: 0, ownerPageSeeds: 0, startupListens: 0 };
function faultDelay(name, maximum) {
  const value = Number(process.env[name] ?? '0');
  if (!Number.isInteger(value) || value < 0 || value > maximum) {
    throw new Error(`${name} must be an integer from 0 to ${maximum}`);
  }
  return value;
}
const firstReadyDelay = faultDelay('AMR_NATIVE_READY_DELAY_MS', 30000);
const firstSeedDelay = faultDelay('AMR_NATIVE_SEED_DELAY_MS', 10000);
const firstTransportDelay = faultDelay('AMR_NATIVE_TRANSPORT_DELAY_MS', 35000);
let backendReady = false;

class BackendHTTPError extends Error {
  constructor(status) {
    super(`Fixture backend returned HTTP ${status}`);
    this.status = status;
  }
}

async function backendDocument(method, document, fields, timeoutMs, delayMs = 0) {
  const started = performance.now();
  const signal = AbortSignal.timeout(Math.max(1, Math.ceil(timeoutMs)));
  console.log(`Native SDK backend ${method} ${document} started at ${new Date().toISOString()}; budget=${Math.ceil(timeoutMs)}ms`);
  try {
    if (delayMs > 0) await new Promise(resolve => setTimeout(resolve, delayMs));
    const response = await fetch(`http://${backend}/v1/projects/${project}/databases/(default)/documents/${document}`, {
      method,
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer owner' },
      ...(fields ? { body: JSON.stringify({ fields }) } : {}),
      redirect: 'error', // The fixture must never follow a loopback response off-host.
      signal
    });
    const body = await response.text();
    console.log(`Native SDK backend ${method} ${document} HTTP ${response.status} after ${Math.round(performance.now() - started)}ms`);
    if (!response.ok) throw new BackendHTTPError(response.status);
    return body ? JSON.parse(body) : {};
  } catch (error) {
    console.error(`Native SDK backend ${method} ${document} failed after ${Math.round(performance.now() - started)}ms: ${error.name}: ${error.message}`);
    throw error;
  }
}

function ownerPageID(index) {
  return `00000000-0000-0000-0000-${index.toString(16).toUpperCase().padStart(12, '0')}`;
}

async function seedOwnerPages() {
  const documents = [
    ...Array.from({ length: 130 }, (_, index) => ({ id: ownerPageID(index * 2), owner: 'fixture-owner' })),
    ...Array.from({ length: 10 }, (_, index) => ({ id: ownerPageID(1000 + index), owner: 'fixture-small' })),
    { id: ownerPageID(31), owner: 'foreign-owner' },
    { id: ownerPageID(95), owner: 'foreign-owner' }
  ];
  // Bound fixture setup too: eight loopback PATCH requests at a time, each
  // with one exact document ID. No public collection endpoint is involved.
  for (let offset = 0; offset < documents.length; offset += 8) {
    await Promise.all(documents.slice(offset, offset + 8).map(({ id, owner }) =>
      backendDocument('PATCH', `drops/${id}`, {
        ownerUid: { stringValue: owner },
        drop: { mapValue: { fields: {
          id: { stringValue: id },
          ownerUid: { stringValue: owner },
          message: { stringValue: `server-${id}` }
        } } }
      }, 20000)));
  }
  console.log(`Native owner-page fixture seeded ${documents.length} documents`);
}

async function warmBackend() {
  const started = performance.now();
  const deadline = started + 60000;
  // Reuse one document and identical payload if a transient failure leaves the
  // write acknowledgement uncertain. Never retry a native test's seed POST.
  const document = `nativeWarmup/${randomUUID()}`;
  const marker = 'native-sdk-backend-ready';
  let attempt = 0;
  let lastError;
  while (performance.now() < deadline) {
    attempt++;
    console.log(`Native SDK backend warm-up attempt ${attempt}`);
    const request = (method, fields) => {
      const remaining = deadline - performance.now();
      if (remaining <= 0) throw new DOMException('Warm-up budget exhausted', 'TimeoutError');
      return backendDocument(method, document, fields, Math.min(15000, remaining));
    };
    try {
      await request('PATCH', { marker: { stringValue: marker } });
      const read = await request('GET');
      if (read.name !== `projects/${project}/databases/(default)/documents/${document}` ||
          read.fields?.marker?.stringValue !== marker) {
        throw new Error('Fixture backend warm-up returned the wrong document or marker');
      }
      await request('DELETE');
      backendReady = true;
      console.log(`Native SDK backend warm-up passed after ${attempt} attempt(s), ${Math.round(performance.now() - started)}ms; launching tests next`);
      return;
    } catch (error) {
      const transient = error.name === 'TimeoutError' || error.name === 'AbortError' ||
        (error instanceof TypeError && error.message === 'fetch failed' &&
          ['ECONNREFUSED', 'ECONNRESET', 'EPIPE', 'ETIMEDOUT', 'UND_ERR_CONNECT_TIMEOUT',
            'UND_ERR_HEADERS_TIMEOUT', 'UND_ERR_SOCKET'].includes(error.cause?.code)) ||
        (error instanceof BackendHTTPError && [408, 429, 500, 502, 503, 504].includes(error.status));
      if (!transient) throw error;
      lastError = `${error.name}: ${error.message}`;
      await new Promise(resolve => setTimeout(resolve, Math.min(250, Math.max(0, deadline - performance.now()))));
    }
  }
  throw new Error(`Fixture backend warm-up exceeded 60000ms after ${attempt} attempt(s): ${lastError}`);
}

function forward(stream, headers) {
  if (stream.destroyed || stream.closed) return;
  const upstream = http2.connect(`http://${backend}`);
  upstreamSessions.add(upstream);
  upstream.on('error', () => stream.close(http2.constants.NGHTTP2_INTERNAL_ERROR));
  upstream.on('close', () => upstreamSessions.delete(upstream));
  const request = upstream.request({ ...headers, ':authority': backend });
  let trailers = {};
  request.on('response', responseHeaders => {
    const forwarded = { ...responseHeaders };
    // A gRPC refusal may be a single HEADERS+END_STREAM response. Our proxy
    // emits a body stream, so move status fields to its actual final trailers.
    // Sending them only in the first headers plus empty trailers loses code 7.
    for (const key of ['grpc-status', 'grpc-message', 'grpc-status-details-bin']) {
      if (key in forwarded) {
        trailers[key] = forwarded[key];
        delete forwarded[key];
      }
    }
    if (!stream.destroyed && !stream.closed) {
      stream.respond(forwarded, { waitForTrailers: true });
    }
  });
  request.on('trailers', value => { trailers = { ...trailers, ...value }; });
  stream.on('wantTrailers', () => {
    if (!stream.destroyed && !stream.closed) stream.sendTrailers(trailers);
  });
  request.on('error', () => {
    if (!stream.destroyed && !stream.closed) stream.close(http2.constants.NGHTTP2_INTERNAL_ERROR);
  });
  request.on('close', () => upstream.close());
  stream.on('close', () => {
    if (!request.closed) request.close();
    upstream.close();
  });
  stream.pipe(request);
  request.pipe(stream);
  stream.resume();
}

function release(kind) {
  for (const item of [...held]) {
    if (item.kind !== kind) continue;
    held.delete(item);
    forward(item.stream, item.headers);
  }
}

const proxy = http2.createServer();
proxy.on('session', session => {
  incomingSessions.add(session);
  session.on('error', () => {});
  session.on('close', () => incomingSessions.delete(session));
});
proxy.on('stream', (stream, headers) => {
  stream.on('error', () => {});
  const path = headers[':path'];
  if (path?.endsWith('/Listen') && counters.startupListens === 0) {
    counters.startupListens++;
    if (firstTransportDelay > 0) {
      console.log(`Native SDK first Listen delayed by ${firstTransportDelay}ms for startup validation`);
      stream.pause();
      setTimeout(() => forward(stream, headers), firstTransportDelay);
      return;
    }
  }
  const kind = path?.endsWith('/Write') ? 'writes' :
    path?.endsWith('/BatchGetDocuments') || path?.endsWith('/Commit') ? 'reads' : null;
  if ((kind === 'writes' && holdWrites) || (kind === 'reads' && holdReads)) {
    stream.pause();
    const item = { stream, headers, kind };
    held.add(item);
    counters[kind === 'writes' ? 'heldWrites' : 'heldReads']++;
    stream.on('close', () => held.delete(item));
  } else {
    forward(stream, headers);
  }
});

const control = http.createServer(async (request, response) => {
  const started = performance.now();
  const path = new URL(request.url, 'http://127.0.0.1').pathname;
  console.log(`Native SDK control ${request.method} ${path} received at ${new Date().toISOString()}`);
  response.on('finish', () => {
    console.log(`Native SDK control ${request.method} ${path} replied HTTP ${response.statusCode} after ${Math.round(performance.now() - started)}ms`);
  });
  response.on('close', () => {
    if (!response.writableFinished) console.error(`Native SDK control ${request.method} ${path} client closed before reply after ${Math.round(performance.now() - started)}ms`);
  });
  try {
    if (request.method === 'GET' && path === '/ready') {
      counters.readyRequests++;
      console.log(`Native SDK readiness request ${counters.readyRequests} received at ${new Date().toISOString()}`);
      // Opt-in fault injection validates first-request timeout/retry without
      // loosening the actual Firestore deadline or allowing a skipped test.
      if (counters.readyRequests === 1 && firstReadyDelay > 0) {
        await new Promise(resolve => setTimeout(resolve, firstReadyDelay));
      }
      if (response.destroyed) return;
      response.end(JSON.stringify({ project, backendReady, ...counters }));
      return;
    }
    if (request.method !== 'POST') {
      response.writeHead(405).end();
      return;
    }
    const seed = /^\/seed\/(rejected|accepted|denied)\/([a-zA-Z0-9-]+)$/.exec(path);
    if (seed) {
      const [, kind, id] = seed;
      counters.seedRequests++;
      await backendDocument('PATCH', `probe/${id}`, {
        readable: { booleanValue: kind !== 'denied' },
        allowDelete: { booleanValue: kind === 'accepted' },
        marker: { stringValue: 'server-existing' }
      }, 20000, counters.seedRequests === 1 ? firstSeedDelay : 0);
    } else if (path === '/seed-owner-pages') {
      if (counters.ownerPageSeeds !== 0) throw new Error('Owner pages can be seeded only once');
      counters.ownerPageSeeds++;
      await seedOwnerPages();
    } else if (path === '/hold-writes') {
      holdWrites = true;
    } else if (path === '/release-writes') {
      holdWrites = false;
      release('writes');
    } else if (path === '/hold-reads') {
      holdReads = true;
    } else if (path === '/release-reads') {
      holdReads = false;
      release('reads');
    } else {
      response.writeHead(404).end();
      return;
    }
    if (!response.destroyed) response.end(JSON.stringify({ project, backendReady, ...counters }));
  } catch (error) {
    console.error(`Native SDK control ${request.method} ${path} failed: ${error.name}: ${error.message}`);
    if (!response.destroyed) response.writeHead(500).end(String(error));
  }
});

// Listening ports do not prove that the emulator's database has initialized.
// Complete a real backend round trip before consuming simulator/test resources.
await warmBackend();
await Promise.all([
  new Promise((resolve, reject) => {
    proxy.once('error', reject);
    proxy.listen(8189, '127.0.0.1', resolve);
  }),
  new Promise((resolve, reject) => {
    control.once('error', reject);
    control.listen(8187, '127.0.0.1', resolve);
  })
]);
console.log(`Native SDK fixture ready: ${project}; control8187/proxy8189 -> ${backend}`);
const child = spawn(command[0], command.slice(1), { stdio: 'inherit', env: process.env });
const code = await new Promise(resolve => {
  child.on('error', error => { console.error(error); resolve(1); });
  child.on('exit', value => resolve(value ?? 1));
});
console.log(`Native SDK gate counters: ${JSON.stringify(counters)}`);
const exercisedNativeGate = counters.heldWrites > 0 && counters.heldReads > 0 &&
  counters.seedRequests === 3 && counters.ownerPageSeeds === 1;
if (code === 0 && !exercisedNativeGate) {
  console.error('Native regression requires both RPC gates, three document seeds and one owner-page seed; skips, empty selections, or duplicated mutations cannot pass');
}
for (const session of incomingSessions) session.destroy();
for (const session of upstreamSessions) session.destroy();
await Promise.all([new Promise(resolve => control.close(resolve)), new Promise(resolve => proxy.close(resolve))]);
process.exitCode = code || (exercisedNativeGate ? 0 : 1);
