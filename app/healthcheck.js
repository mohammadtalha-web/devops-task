'use strict';

// Used by Docker HEALTHCHECK. The image has no curl/wget, so we use Node itself.
const http = require('node:http');

const req = http.get({ host: '127.0.0.1', port: process.env.PORT || 8080, path: '/health', timeout: 2000 }, (res) => {
  res.resume();
  process.exit(res.statusCode === 200 ? 0 : 1);
});
req.on('timeout', () => req.destroy());
req.on('error', () => process.exit(1));
