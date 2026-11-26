'use strict';

const LOG_LEVELS = ['debug', 'info', 'warn', 'error'];

function intFromEnv(env, name, fallback, { min, max }) {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new Error(`Invalid ${name}: "${raw}" (expected integer ${min}-${max})`);
  }
  return value;
}

/** All configuration comes from environment variables (12-factor). */
function loadConfig(env = process.env) {
  const logLevel = (env.LOG_LEVEL || 'info').toLowerCase();
  if (!LOG_LEVELS.includes(logLevel)) {
    throw new Error(`Invalid LOG_LEVEL: "${env.LOG_LEVEL}" (expected one of ${LOG_LEVELS.join(', ')})`);
  }
  return {
    port: intFromEnv(env, 'PORT', 8080, { min: 0, max: 65535 }),
    logLevel,
    environment: env.APP_ENV || 'local',
    version: env.APP_VERSION || require('../package.json').version,
    shutdownTimeoutMs: intFromEnv(env, 'SHUTDOWN_TIMEOUT_MS', 10000, { min: 100, max: 120000 }),
    // Demo-only switch that exposes GET /boom (always 500) to generate an error spike.
    enableChaos: env.ENABLE_CHAOS === 'true',
    // Example of a secret-backed value: only its presence is ever logged, never the value.
    apiKeyConfigured: Boolean(env.API_KEY),
  };
}

module.exports = { loadConfig, LOG_LEVELS };
