'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { Writable } = require('node:stream');
const { loadConfig } = require('../src/config');
const { createLogger } = require('../src/logger');
const { createApp, installShutdown } = require('../src/server');

const lines = [];
const sink = new Writable({ write(chunk, _enc, cb) { lines.push(chunk.toString()); cb(); } });
const logger = createLogger({ level: 'debug', stream: sink, base: { service: 'app' } });

let app;
let chaosApp;
let base;
let chaosBase;

const listen = (a) => new Promise((resolve) => {
  a.server.listen(0, '127.0.0.1', () => resolve(`http://127.0.0.1:${a.server.address().port}`));
});

before(async () => {
  app = createApp({ config: loadConfig({ APP_VERSION: '9.9.9', APP_ENV: 'test' }), logger });
  chaosApp = createApp({ config: loadConfig({ ENABLE_CHAOS: 'true' }), logger });
  base = await listen(app);
  chaosBase = await listen(chaosApp);
});

after(() => {
  app.server.close();
  chaosApp.server.close();
  app.server.closeAllConnections();
  chaosApp.server.closeAllConnections();
});

test('GET / returns greeting, status and version', async () => {
  const res = await fetch(`${base}/`);
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /application\/json/);
  assert.deepEqual(await res.json(), { message: 'Hello from DevOps Task!', status: 'running', version: '9.9.9' });
});

test('GET /health returns 200 ok', async () => {
  const res = await fetch(`${base}/health`);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { status: 'ok' });
});

test('GET /health returns 503 while shutting down', async () => {
  const local = createApp({ config: loadConfig({}), logger });
  const url = await listen(local);
  local.state.shuttingDown = true;
  const res = await fetch(`${url}/health`);
  assert.equal(res.status, 503);
  assert.equal((await res.json()).status, 'shutting_down');
  local.server.closeAllConnections();
  local.server.close();
});

test('GET /metrics exposes request counter, error counter and latency histogram', async () => {
  await fetch(`${base}/`);
  const res = await fetch(`${base}/metrics`);
  const body = await res.text();
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /text\/plain/);
  assert.match(body, /# TYPE http_requests_total counter/);
  assert.match(body, /http_requests_total\{method="GET",route="\/",status="200"\} \d+/);
  assert.match(body, /# TYPE http_errors_total counter/);
  assert.match(body, /http_errors_total\{method="GET",route="\/"\} 0/);
  assert.match(body, /# TYPE http_request_duration_seconds histogram/);
  assert.match(body, /http_request_duration_seconds_bucket\{method="GET",route="\/",le="\+Inf"\} \d+/);
  assert.match(body, /http_request_duration_seconds_count\{method="GET",route="\/"\} \d+/);
  assert.match(body, /app_info\{version="9.9.9",environment="test"\} 1/);
});

test('unknown paths return 404 and use a bounded route label', async () => {
  const res = await fetch(`${base}/does-not-exist-123`);
  assert.equal(res.status, 404);
  const body = await (await fetch(`${base}/metrics`)).text();
  assert.match(body, /route="unmatched",status="404"/);
  assert.doesNotMatch(body, /does-not-exist-123/);
});

test('non-GET methods return 405', async () => {
  const res = await fetch(`${base}/`, { method: 'POST' });
  assert.equal(res.status, 405);
  assert.equal(res.headers.get('allow'), 'GET');
});

test('/boom is not routable unless chaos is enabled', async () => {
  assert.equal((await fetch(`${base}/boom`)).status, 404);
});

test('/boom returns 500 and increments the error counter when chaos is enabled', async () => {
  assert.equal((await fetch(`${chaosBase}/boom`)).status, 500);
  const body = await (await fetch(`${chaosBase}/metrics`)).text();
  assert.match(body, /http_errors_total\{method="GET",route="\/boom"\} 1/);
});

test('logs are structured JSON with level and path fields', async () => {
  await fetch(`${base}/?x=1`);
  const entries = lines.map((l) => JSON.parse(l));
  const entry = entries.reverse().find((e) => e.msg === 'request' && e.route === '/');
  assert.ok(entry);
  assert.equal(entry.level, 'info');
  assert.equal(entry.path, '/');
  assert.equal(entry.status, 200);
  assert.equal(entry.service, 'app');
  assert.ok(typeof entry.duration_ms === 'number');
});

test('logger respects LOG_LEVEL', () => {
  const out = [];
  const quiet = createLogger({ level: 'warn', stream: { write: (s) => out.push(s) } });
  quiet.info('hidden');
  quiet.warn('shown');
  assert.equal(out.length, 1);
  assert.equal(JSON.parse(out[0]).msg, 'shown');
});

test('config reads env vars and validates them', () => {
  const c = loadConfig({ PORT: '3000', LOG_LEVEL: 'DEBUG', APP_ENV: 'prod', API_KEY: 'x' });
  assert.equal(c.port, 3000);
  assert.equal(c.logLevel, 'debug');
  assert.equal(c.environment, 'prod');
  assert.equal(c.apiKeyConfigured, true);
  assert.equal(loadConfig({}).port, 8080);
  assert.throws(() => loadConfig({ PORT: 'abc' }), /Invalid PORT/);
  assert.throws(() => loadConfig({ LOG_LEVEL: 'loud' }), /Invalid LOG_LEVEL/);
});

test('graceful shutdown fails readiness, closes the server and exits 0', async () => {
  const local = createApp({ config: loadConfig({}), logger });
  await listen(local);
  const exits = [];
  const done = new Promise((resolve) => {
    const shutdown = installShutdown({
      ...local, logger, timeoutMs: 2000,
      exit: (code) => { exits.push(code); resolve(); },
    });
    shutdown('SIGTERM');
    shutdown('SIGTERM'); // idempotent
  });
  assert.equal(local.state.shuttingDown, true);
  await done;
  assert.deepEqual(exits, [0]);
});
