'use strict';

const http = require('node:http');
const { Metrics } = require('./metrics');

const BASE_ROUTES = ['/', '/health', '/metrics'];

function createApp({ config, logger }) {
  const state = { shuttingDown: false };
  const routes = config.enableChaos ? [...BASE_ROUTES, '/boom'] : BASE_ROUTES;
  const metrics = new Metrics({ version: config.version, environment: config.environment, knownRoutes: routes });

  const send = (res, status, body, headers = {}) => {
    const payload = typeof body === 'string' ? body : JSON.stringify(body);
    res.writeHead(status, {
      'Content-Type': typeof body === 'string' ? 'text/plain; version=0.0.4; charset=utf-8' : 'application/json',
      'Content-Length': Buffer.byteLength(payload),
      ...headers,
    });
    res.end(payload);
  };

  const server = http.createServer((req, res) => {
    const start = process.hrtime.bigint();
    const path = (req.url || '/').split('?')[0];
    const route = routes.includes(path) ? path : 'unmatched';
    // Behind an ALB/Service, tell clients to reconnect elsewhere while draining.
    if (state.shuttingDown) res.setHeader('Connection', 'close');

    res.on('finish', () => {
      const seconds = Number(process.hrtime.bigint() - start) / 1e9;
      const status = res.statusCode;
      metrics.observe({ method: req.method, route, status, seconds });
      // Probe/scrape traffic is logged at debug to keep info logs useful.
      const noisy = (route === '/health' || route === '/metrics') && status < 500;
      const level = status >= 500 ? 'error' : status >= 400 ? 'warn' : noisy ? 'debug' : 'info';
      logger[level]('request', {
        method: req.method, path: path.slice(0, 200), route, status,
        duration_ms: Math.round(seconds * 1000 * 100) / 100,
      });
    });

    if (route === 'unmatched') return send(res, 404, { error: 'not_found' });
    if (req.method !== 'GET') return send(res, 405, { error: 'method_not_allowed' }, { Allow: 'GET' });

    switch (route) {
      case '/':
        return send(res, 200, { message: 'Hello from DevOps Task!', status: 'running', version: config.version });
      case '/health':
        return state.shuttingDown
          ? send(res, 503, { status: 'shutting_down' })
          : send(res, 200, { status: 'ok' });
      case '/metrics':
        return send(res, 200, metrics.render());
      default: // '/boom' (only routable when ENABLE_CHAOS=true)
        return send(res, 500, { error: 'simulated_failure' });
    }
  });

  // Longer than typical load-balancer idle timeouts (ALB default: 60s) to avoid 502s.
  server.keepAliveTimeout = 65000;
  server.headersTimeout = 66000;

  return { server, state, metrics };
}

/** Graceful shutdown: fail readiness, stop accepting, drain in-flight requests, then exit. */
function installShutdown({ server, state, logger, timeoutMs, exit = process.exit }) {
  let started = false;
  return (signal) => {
    if (started) return;
    started = true;
    state.shuttingDown = true;
    logger.info('shutdown_initiated', { signal });
    const timer = setTimeout(() => {
      logger.error('shutdown_timeout_forcing_exit', { timeout_ms: timeoutMs });
      exit(1);
    }, timeoutMs);
    timer.unref();
    server.close((err) => {
      if (err) {
        logger.error('shutdown_error', { error: err.message });
        return exit(1);
      }
      logger.info('shutdown_complete');
      return exit(0);
    });
    server.closeIdleConnections();
  };
}

module.exports = { createApp, installShutdown };
