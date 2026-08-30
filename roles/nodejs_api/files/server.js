const express = require('express');
const mysql = require('mysql2/promise');
const redis = require('redis');

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3000;
const HOSTNAME = require('os').hostname();

// MySQL primary pool (writes)
const dbPrimary = mysql.createPool({
  host: process.env.DB_PRIMARY_HOST || 'mysql-primary',
  user: process.env.DB_USER || 'appuser',
  password: process.env.DB_PASSWORD || 'apppass',
  database: process.env.DB_NAME || 'appdb',
  waitForConnections: true,
  connectionLimit: 5
});

// Redis client (cache)
const redisClient = redis.createClient({
  url: `redis://${process.env.REDIS_HOST || 'redis'}:6379`
});
redisClient.on('error', (err) => console.error('Redis error:', err));
redisClient.connect();

// Health check
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok', host: HOSTNAME });
});

// Init table
async function initDb() {
  try {
    await dbPrimary.query(`
      CREATE TABLE IF NOT EXISTS items (
        id INT AUTO_INCREMENT PRIMARY KEY,
        name VARCHAR(255) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    `);
    console.log('DB initialized');
  } catch (e) {
    console.error('DB init failed, retrying in 5s:', e.message);
    setTimeout(initDb, 5000);
  }
}
initDb();

// Create item (write -> primary, invalidate cache)
app.post('/items', async (req, res) => {
  try {
    const { name } = req.body;
    const [result] = await dbPrimary.query('INSERT INTO items (name) VALUES (?)', [name]);
    await redisClient.del('items:all');
    res.status(201).json({ id: result.insertId, name, servedBy: HOSTNAME });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: e.message });
  }
});

// Read items (cache-aside from Redis, fallback to primary for simplicity)
app.get('/items', async (req, res) => {
  try {
    const cached = await redisClient.get('items:all');
    if (cached) {
      return res.json({ source: 'cache', servedBy: HOSTNAME, data: JSON.parse(cached) });
    }
    const [rows] = await dbPrimary.query('SELECT * FROM items ORDER BY id DESC LIMIT 50');
    await redisClient.set('items:all', JSON.stringify(rows), { EX: 30 });
    res.json({ source: 'db', servedBy: HOSTNAME, data: rows });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: e.message });
  }
});

app.listen(PORT, () => console.log(`API running on port ${PORT} (${HOSTNAME})`));
