'use strict';

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };

/** Minimal structured logger: one JSON object per line on stdout. */
function createLogger({ level = 'info', stream = process.stdout, base = {} } = {}) {
  const min = LEVELS[level] ?? LEVELS.info;
  const write = (lvl, msg, fields) => {
    if (LEVELS[lvl] < min) return;
    stream.write(`${JSON.stringify({ time: new Date().toISOString(), level: lvl, msg, ...base, ...fields })}\n`);
  };
  return {
    debug: (msg, fields) => write('debug', msg, fields),
    info: (msg, fields) => write('info', msg, fields),
    warn: (msg, fields) => write('warn', msg, fields),
    error: (msg, fields) => write('error', msg, fields),
  };
}

module.exports = { createLogger };
