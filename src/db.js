'use strict';

require('dotenv').config();
const { Pool } = require('pg');

const pool = new Pool({
  host: process.env.DB_HOST || 'localhost',
  port: parseInt(process.env.DB_PORT || '5432', 10),
  database: process.env.DB_NAME || 'scoutops',
  user: process.env.DB_USER || 'scoutops_user',
  password: process.env.DB_PASSWORD,
  max: parseInt(process.env.DB_POOL_MAX || '10', 10),
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

// An idle client erroring must never crash the process.
pool.on('error', (err) => {
  console.error(JSON.stringify({ level: 'error', msg: 'idle pg client error', error: err.message }));
});

/** Run a parameterized query. Values are ALWAYS passed separately from SQL text. */
async function query(text, params = []) {
  return pool.query(text, params);
}

/** Returns true when the database answers a trivial query. Never throws. */
async function healthCheck() {
  try {
    await pool.query('SELECT 1');
    return true;
  } catch (err) {
    console.error(JSON.stringify({ level: 'error', msg: 'db health check failed', error: err.message }));
    return false;
  }
}

let closed = false;
/** Close the pool (idempotent) for graceful shutdown. */
async function close() {
  if (closed) return;
  closed = true;
  await pool.end();
}

module.exports = { pool, query, healthCheck, close };
