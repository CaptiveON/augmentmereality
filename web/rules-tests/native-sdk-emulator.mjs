// Invoke inside emulators:exec for demo-amr-native-sdk. The child is an explicit
// xcodebuild test-without-building command whose xctestrun opts into this probe.
// A loopback HTTP/2 proxy holds only Write RPCs, making a local unacknowledged
// delete deterministic while ordinary server reads and transactions still run.
import http from 'node:http';
import http2 from 'node:http2';
import { spawn } from 'node:child_process';

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
const counters = { heldWrites: 0, heldReads: 0 };

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
  try {
    const path = new URL(request.url, 'http://127.0.0.1').pathname;
    if (request.method === 'GET' && path === '/ready') {
      response.end(JSON.stringify({ project, ...counters }));
      return;
    }
    if (request.method !== 'POST') {
      response.writeHead(405).end();
      return;
    }
    const seed = /^\/seed\/(rejected|accepted|denied)\/([a-zA-Z0-9-]+)$/.exec(path);
    if (seed) {
      const [, kind, id] = seed;
      const result = await fetch(`http://${backend}/v1/projects/${project}/databases/(default)/documents/probe/${id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json', Authorization: 'Bearer owner' },
        body: JSON.stringify({ fields: {
          readable: { booleanValue: kind !== 'denied' },
          allowDelete: { booleanValue: kind === 'accepted' },
          marker: { stringValue: 'server-existing' }
        } })
      });
      if (!result.ok) throw new Error(`Fixture seed failed: ${result.status}`);
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
    response.end(JSON.stringify({ project, ...counters }));
  } catch (error) {
    response.writeHead(500).end(String(error));
  }
});

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
const exercisedNativeGate = counters.heldWrites > 0 && counters.heldReads > 0;
if (code === 0 && !exercisedNativeGate) {
  console.error('Native regression did not exercise both RPC gates; skips or empty selections cannot pass');
}
for (const session of incomingSessions) session.destroy();
for (const session of upstreamSessions) session.destroy();
await Promise.all([new Promise(resolve => control.close(resolve)), new Promise(resolve => proxy.close(resolve))]);
process.exitCode = code || (exercisedNativeGate ? 0 : 1);
