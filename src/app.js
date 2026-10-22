'use strict';

const path = require('path');
const express = require('express');
const client = require('prom-client');
const db = require('./db');

const CATEGORIES = ['ELECTRICAL', 'PLUMBING', 'INTERNET', 'CLEANING', 'FURNITURE', 'EQUIPMENT', 'SECURITY', 'OTHER'];
const PRIORITIES = ['LOW', 'MEDIUM', 'HIGH', 'CRITICAL'];
const STATUSES = ['OPEN', 'ASSIGNED', 'IN_PROGRESS', 'RESOLVED', 'CLOSED'];

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '100kb' }));

// ---------------------------------------------------------------- metrics
const register = new client.Registry();
client.collectDefaultMetrics({ register, prefix: 'scoutops_' });

const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register],
});
const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [register],
});
const httpErrorsTotal = new client.Counter({
  name: 'http_errors_total',
  help: 'Total number of HTTP responses with status >= 400',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register],
});

// ------------------------------------------------- logging + metrics middleware
app.use((req, res, next) => {
  const start = process.hrtime.bigint();
  res.on('finish', () => {
    const seconds = Number(process.hrtime.bigint() - start) / 1e9;
    const route = req.route ? `${req.baseUrl || ''}${req.route.path}` : 'unmatched';
    const labels = { method: req.method, route, status_code: String(res.statusCode) };
    httpRequestsTotal.inc(labels);
    httpRequestDuration.observe(labels, seconds);
    if (res.statusCode >= 400) httpErrorsTotal.inc(labels);
    if (process.env.NODE_ENV !== 'test') {
      console.log(JSON.stringify({
        level: 'info', method: req.method, url: req.originalUrl,
        status: res.statusCode, duration_ms: Math.round(seconds * 1000),
      }));
    }
  });
  next();
});

app.use(express.static(path.join(__dirname, '..', 'public')));

// ------------------------------------------------------------------ helpers
const ISSUE_COLUMNS = 'id, title, description, category, location, priority, status, reporter_name, created_at, updated_at';

function parseId(raw) {
  if (!/^\d+$/.test(String(raw))) return null;
  const id = Number(raw);
  return Number.isSafeInteger(id) && id > 0 && id <= 2147483647 ? id : null;
}

/** Validate an issue body. Returns { errors, value }. */
function validateIssue(body) {
  const errors = [];
  const value = {};
  const src = body && typeof body === 'object' && !Array.isArray(body) ? body : null;
  if (!src) return { errors: ['Request body must be a JSON object'], value };

  const str = (field, min, max, required) => {
    const v = src[field];
    if (v === undefined || v === null) {
      if (required) errors.push(`${field} is required`);
      return;
    }
    if (typeof v !== 'string') return errors.push(`${field} must be a string`);
    const t = v.trim();
    if (t.length < min || t.length > max) {
      return errors.push(`${field} must be between ${min} and ${max} characters`);
    }
    value[field] = t;
  };
  const oneOf = (field, allowed, def) => {
    let v = src[field];
    if (v === undefined || v === null) {
      if (def !== undefined) value[field] = def;
      else errors.push(`${field} is required`);
      return;
    }
    if (typeof v !== 'string') return errors.push(`${field} must be a string`);
    v = v.trim().toUpperCase();
    if (!allowed.includes(v)) return errors.push(`${field} must be one of: ${allowed.join(', ')}`);
    value[field] = v;
  };

  str('title', 3, 150, true);
  str('description', 0, 2000, false);
  str('location', 2, 150, true);
  str('reporter_name', 2, 100, true);
  oneOf('category', CATEGORIES);
  oneOf('priority', PRIORITIES, 'MEDIUM');
  oneOf('status', STATUSES, 'OPEN');
  if (value.description === undefined) value.description = '';
  return { errors, value };
}

function sendDbError(res, err) {
  console.error(JSON.stringify({ level: 'error', msg: 'database error', error: err.message }));
  return res.status(503).json({ error: 'Database error. Please try again later.' });
}

// ------------------------------------------------------------ health + metrics
app.get('/health', (req, res) => res.json({ status: 'UP', service: 'scoutops' }));

app.get('/health/db', async (req, res) => {
  const ok = await db.healthCheck();
  if (ok) return res.json({ status: 'UP', service: 'scoutops', database: 'UP' });
  return res.status(503).json({ status: 'DOWN', service: 'scoutops', database: 'DOWN' });
});

app.get('/metrics', async (req, res) => {
  try {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  } catch (err) {
    res.status(500).json({ error: 'Could not collect metrics' });
  }
});

// ---------------------------------------------------------------- issues API
app.get('/api/issues', async (req, res) => {
  const where = [];
  const params = [];
  for (const [field, allowed] of [['status', STATUSES], ['priority', PRIORITIES], ['category', CATEGORIES]]) {
    if (req.query[field] !== undefined) {
      const v = String(req.query[field]).toUpperCase();
      if (!allowed.includes(v)) {
        return res.status(400).json({ error: `Invalid ${field} filter`, allowed });
      }
      params.push(v);
      where.push(`${field} = $${params.length}`);
    }
  }
  const sql = `SELECT ${ISSUE_COLUMNS} FROM issues${where.length ? ` WHERE ${where.join(' AND ')}` : ''} ORDER BY created_at DESC, id DESC`;
  try {
    const { rows } = await db.query(sql, params);
    res.json(rows);
  } catch (err) {
    sendDbError(res, err);
  }
});

app.get('/api/issues/:id', async (req, res) => {
  const id = parseId(req.params.id);
  if (!id) return res.status(400).json({ error: 'Issue id must be a positive integer' });
  try {
    const { rows } = await db.query(`SELECT ${ISSUE_COLUMNS} FROM issues WHERE id = $1`, [id]);
    if (!rows.length) return res.status(404).json({ error: 'Issue not found' });
    res.json(rows[0]);
  } catch (err) {
    sendDbError(res, err);
  }
});

app.post('/api/issues', async (req, res) => {
  const { errors, value } = validateIssue(req.body);
  if (errors.length) return res.status(400).json({ error: 'Validation failed', details: errors });
  try {
    const { rows } = await db.query(
      `INSERT INTO issues (title, description, category, location, priority, status, reporter_name)
       VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING ${ISSUE_COLUMNS}`,
      [value.title, value.description, value.category, value.location, value.priority, value.status, value.reporter_name]
    );
    res.status(201).json(rows[0]);
  } catch (err) {
    sendDbError(res, err);
  }
});

app.put('/api/issues/:id', async (req, res) => {
  const id = parseId(req.params.id);
  if (!id) return res.status(400).json({ error: 'Issue id must be a positive integer' });
  const { errors, value } = validateIssue(req.body);
  if (errors.length) return res.status(400).json({ error: 'Validation failed', details: errors });
  try {
    const { rows } = await db.query(
      `UPDATE issues SET title = $1, description = $2, category = $3, location = $4,
              priority = $5, status = $6, reporter_name = $7, updated_at = NOW()
       WHERE id = $8 RETURNING ${ISSUE_COLUMNS}`,
      [value.title, value.description, value.category, value.location, value.priority, value.status, value.reporter_name, id]
    );
    if (!rows.length) return res.status(404).json({ error: 'Issue not found' });
    res.json(rows[0]);
  } catch (err) {
    sendDbError(res, err);
  }
});

app.patch('/api/issues/:id/status', async (req, res) => {
  const id = parseId(req.params.id);
  if (!id) return res.status(400).json({ error: 'Issue id must be a positive integer' });
  const raw = req.body && typeof req.body.status === 'string' ? req.body.status.trim().toUpperCase() : null;
  if (!raw || !STATUSES.includes(raw)) {
    return res.status(400).json({ error: 'Validation failed', details: [`status must be one of: ${STATUSES.join(', ')}`] });
  }
  try {
    const { rows } = await db.query(
      `UPDATE issues SET status = $1, updated_at = NOW() WHERE id = $2 RETURNING ${ISSUE_COLUMNS}`,
      [raw, id]
    );
    if (!rows.length) return res.status(404).json({ error: 'Issue not found' });
    res.json(rows[0]);
  } catch (err) {
    sendDbError(res, err);
  }
});

app.delete('/api/issues/:id', async (req, res) => {
  const id = parseId(req.params.id);
  if (!id) return res.status(400).json({ error: 'Issue id must be a positive integer' });
  try {
    const { rows } = await db.query('DELETE FROM issues WHERE id = $1 RETURNING id', [id]);
    if (!rows.length) return res.status(404).json({ error: 'Issue not found' });
    res.json({ message: 'Issue deleted', id: rows[0].id });
  } catch (err) {
    sendDbError(res, err);
  }
});

// ------------------------------------------------------------ error handling
app.use('/api', (req, res) => res.status(404).json({ error: 'Not found' }));

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  if (err && (err.type === 'entity.parse.failed' || err instanceof SyntaxError)) {
    return res.status(400).json({ error: 'Malformed JSON body' });
  }
  if (err && err.type === 'entity.too.large') {
    return res.status(413).json({ error: 'Request body too large' });
  }
  console.error(JSON.stringify({ level: 'error', msg: 'unhandled error', error: err && err.message }));
  res.status(500).json({ error: 'Internal server error' });
});

module.exports = app;
