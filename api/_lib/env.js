'use strict';

function requireEnv(name) {
  const value = process.env[name];
  if (!value || !String(value).trim()) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return String(value).trim();
}

function optionalEnv(name, fallback = '') {
  const value = process.env[name];
  if (!value || !String(value).trim()) return fallback;
  return String(value).trim();
}

module.exports = { requireEnv, optionalEnv };
