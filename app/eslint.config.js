'use strict';

// Dependency-free flat config: no plugins/imports, so `npx eslint` works anywhere.
const nodeGlobals = {
  require: 'readonly', module: 'writable', process: 'readonly', console: 'readonly',
  __dirname: 'readonly', setTimeout: 'readonly', clearTimeout: 'readonly',
  fetch: 'readonly', URL: 'readonly', Buffer: 'readonly',
};

module.exports = [
  { ignores: ['coverage/**', 'node_modules/**'] },
  {
    files: ['**/*.js'],
    languageOptions: { ecmaVersion: 2023, sourceType: 'commonjs', globals: nodeGlobals },
    rules: {
      'no-undef': 'error',
      'no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
      eqeqeq: 'error',
      'no-var': 'error',
      'prefer-const': 'error',
      strict: ['error', 'global'],
    },
  },
];
