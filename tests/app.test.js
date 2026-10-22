'use strict';

process.env.NODE_ENV = 'test';

// The database module is mocked so tests run without PostgreSQL (CI friendly).
jest.mock('../src/db', () => ({
  query: jest.fn(),
  healthCheck: jest.fn(),
  close: jest.fn(),
}));

const request = require('supertest');
const db = require('../src/db');
const app = require('../src/app');

const sampleIssue = {
  id: 1,
  title: 'Projector not turning on',
  description: 'No power',
  category: 'EQUIPMENT',
  location: 'Block A, Room 204',
  priority: 'HIGH',
  status: 'OPEN',
  reporter_name: 'Ananya Rao',
  created_at: '2026-01-01T00:00:00.000Z',
  updated_at: '2026-01-01T00:00:00.000Z',
};

const validBody = {
  title: 'Projector not turning on',
  description: 'No power',
  category: 'EQUIPMENT',
  location: 'Block A, Room 204',
  priority: 'HIGH',
  reporter_name: 'Ananya Rao',
};

beforeEach(() => {
  db.query.mockReset();
  db.healthCheck.mockReset();
});

describe('static + health + metrics', () => {
  test('GET / serves the ScoutOps UI', async () => {
    const res = await request(app).get('/');
    expect(res.status).toBe(200);
    expect(res.text).toContain('SCOUTOPS');
    expect(res.text).toContain('Find. Track. Resolve.');
  });

  test('GET /health returns UP', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'UP', service: 'scoutops' });
  });

  test('GET /health/db returns 200 when database is reachable', async () => {
    db.healthCheck.mockResolvedValue(true);
    const res = await request(app).get('/health/db');
    expect(res.status).toBe(200);
    expect(res.body.database).toBe('UP');
  });

  test('GET /health/db returns 503 when database is down', async () => {
    db.healthCheck.mockResolvedValue(false);
    const res = await request(app).get('/health/db');
    expect(res.status).toBe(503);
    expect(res.body.database).toBe('DOWN');
  });

  test('GET /metrics exposes Prometheus metrics', async () => {
    await request(app).get('/health');
    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/text\/plain/);
    expect(res.text).toContain('http_requests_total');
    expect(res.text).toContain('http_request_duration_seconds');
    expect(res.text).toContain('scoutops_process_cpu_user_seconds_total');
  });
});

describe('issues API', () => {
  test('GET /api/issues lists issues', async () => {
    db.query.mockResolvedValue({ rows: [sampleIssue] });
    const res = await request(app).get('/api/issues');
    expect(res.status).toBe(200);
    expect(res.body).toHaveLength(1);
    expect(res.body[0].title).toBe(sampleIssue.title);
  });

  test('GET /api/issues filters with parameterized SQL', async () => {
    db.query.mockResolvedValue({ rows: [] });
    const res = await request(app).get('/api/issues?status=open');
    expect(res.status).toBe(200);
    const [sql, params] = db.query.mock.calls[0];
    expect(sql).toContain('status = $1');
    expect(params).toEqual(['OPEN']);
  });

  test('GET /api/issues rejects invalid filter', async () => {
    const res = await request(app).get("/api/issues?status=x'; DROP TABLE issues;--");
    expect(res.status).toBe(400);
    expect(db.query).not.toHaveBeenCalled();
  });

  test('GET /api/issues returns 503 on database error', async () => {
    db.query.mockRejectedValue(new Error('connection refused'));
    const res = await request(app).get('/api/issues');
    expect(res.status).toBe(503);
  });

  test('GET /api/issues/:id returns 404 for a missing issue', async () => {
    db.query.mockResolvedValue({ rows: [] });
    const res = await request(app).get('/api/issues/9999');
    expect(res.status).toBe(404);
  });

  test('GET /api/issues/:id returns 400 for a non-numeric id', async () => {
    const res = await request(app).get('/api/issues/abc');
    expect(res.status).toBe(400);
  });

  test('GET /api/issues/:id returns the issue', async () => {
    db.query.mockResolvedValue({ rows: [sampleIssue] });
    const res = await request(app).get('/api/issues/1');
    expect(res.status).toBe(200);
    expect(res.body.id).toBe(1);
  });

  test('POST /api/issues rejects an invalid request', async () => {
    const res = await request(app).post('/api/issues').send({ title: 'x', category: 'NOPE' });
    expect(res.status).toBe(400);
    expect(res.body.details.length).toBeGreaterThan(0);
    expect(db.query).not.toHaveBeenCalled();
  });

  test('POST /api/issues rejects malformed JSON', async () => {
    const res = await request(app).post('/api/issues').set('Content-Type', 'application/json').send('{bad json');
    expect(res.status).toBe(400);
  });

  test('POST /api/issues creates an issue', async () => {
    db.query.mockResolvedValue({ rows: [sampleIssue] });
    const res = await request(app).post('/api/issues').send(validBody);
    expect(res.status).toBe(201);
    expect(res.body.id).toBe(1);
    const [sql, params] = db.query.mock.calls[0];
    expect(sql).toContain('INSERT INTO issues');
    expect(sql).not.toContain(validBody.title);
    expect(params).toContain(validBody.title);
  });

  test('PUT /api/issues/:id updates an issue', async () => {
    db.query.mockResolvedValue({ rows: [{ ...sampleIssue, title: 'Updated title' }] });
    const res = await request(app).put('/api/issues/1').send({ ...validBody, title: 'Updated title', status: 'ASSIGNED' });
    expect(res.status).toBe(200);
    expect(res.body.title).toBe('Updated title');
  });

  test('PUT /api/issues/:id returns 404 for a missing issue', async () => {
    db.query.mockResolvedValue({ rows: [] });
    const res = await request(app).put('/api/issues/42').send(validBody);
    expect(res.status).toBe(404);
  });

  test('PATCH /api/issues/:id/status changes status', async () => {
    db.query.mockResolvedValue({ rows: [{ ...sampleIssue, status: 'RESOLVED' }] });
    const res = await request(app).patch('/api/issues/1/status').send({ status: 'resolved' });
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('RESOLVED');
    expect(db.query.mock.calls[0][1]).toEqual(['RESOLVED', 1]);
  });

  test('PATCH /api/issues/:id/status rejects an invalid status', async () => {
    const res = await request(app).patch('/api/issues/1/status').send({ status: 'DONE' });
    expect(res.status).toBe(400);
  });

  test('PATCH /api/issues/:id/status returns 404 for a missing issue', async () => {
    db.query.mockResolvedValue({ rows: [] });
    const res = await request(app).patch('/api/issues/77/status').send({ status: 'CLOSED' });
    expect(res.status).toBe(404);
  });

  test('DELETE /api/issues/:id deletes an issue', async () => {
    db.query.mockResolvedValue({ rows: [{ id: 1 }] });
    const res = await request(app).delete('/api/issues/1');
    expect(res.status).toBe(200);
    expect(res.body.id).toBe(1);
  });

  test('DELETE /api/issues/:id returns 404 for a missing issue', async () => {
    db.query.mockResolvedValue({ rows: [] });
    const res = await request(app).delete('/api/issues/1');
    expect(res.status).toBe(404);
  });

  test('unknown API route returns JSON 404', async () => {
    const res = await request(app).get('/api/nothing');
    expect(res.status).toBe(404);
    expect(res.body.error).toBeDefined();
  });
});
