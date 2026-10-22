'use strict';

require('dotenv').config();
const app = require('./app');
const db = require('./db');

const PORT = parseInt(process.env.PORT || '3000', 10);

const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(JSON.stringify({ level: 'info', msg: `ScoutOps listening on port ${PORT}` }));
});

let shuttingDown = false;
async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(JSON.stringify({ level: 'info', msg: `${signal} received, shutting down` }));
  const force = setTimeout(() => {
    console.error(JSON.stringify({ level: 'error', msg: 'forced shutdown after timeout' }));
    process.exit(1);
  }, 10000);
  force.unref();
  server.close(async () => {
    try {
      await db.close();
      process.exit(0);
    } catch (err) {
      console.error(JSON.stringify({ level: 'error', msg: 'error closing db', error: err.message }));
      process.exit(1);
    }
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
