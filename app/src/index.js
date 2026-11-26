'use strict';

const { loadConfig } = require('./config');
const { createLogger } = require('./logger');
const { createApp, installShutdown } = require('./server');

let config;
try {
  config = loadConfig();
} catch (err) {
  process.stdout.write(`${JSON.stringify({ time: new Date().toISOString(), level: 'error', msg: 'invalid_config', error: err.message })}\n`);
  process.exit(1);
}

const logger = createLogger({ level: config.logLevel, base: { service: 'app', env: config.environment } });
const { server, state } = createApp({ config, logger });
const shutdown = installShutdown({ server, state, logger, timeoutMs: config.shutdownTimeoutMs });

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('uncaughtException', (err) => {
  logger.error('uncaught_exception', { error: err.message });
  process.exit(1);
});

server.listen(config.port, '0.0.0.0', () => {
  logger.info('server_started', {
    port: config.port, version: config.version, log_level: config.logLevel,
    chaos_enabled: config.enableChaos, api_key_configured: config.apiKeyConfigured,
  });
});
