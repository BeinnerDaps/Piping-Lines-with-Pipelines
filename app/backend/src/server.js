const express = require('express');
const client = require('prom-client');
const cors = require('cors');
const { Pool } = require('pg');
require('dotenv').config();

const app = express();

// ==========================================
// PROMETHEUS METRICS CONFIGURATION
// ==========================================

client.collectDefaultMetrics({ prefix: 'nodejs_' });

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.1, 0.3, 0.5, 1, 1.5, 2, 5] // Time buckets in seconds
});

const tasksCreatedCounter = new client.Counter({
  name: 'tasks_created_total',
  help: 'Total number of tasks created',
  labelNames: ['status']
});

const tasksCompletedCounter = new client.Counter({
  name: 'tasks_completed_total',
  help: 'Total number of tasks completed',
  labelNames: ['status']
});

const userActivityCounter = new client.Counter({
  name: 'user_activity_total',
  help: 'Total user interactions by action type',
  labelNames: ['action']
});

tasksCreatedCounter.inc({ status: 'TODO' }, 0);
tasksCreatedCounter.inc({ status: 'IN_PROGRESS' }, 0);
tasksCreatedCounter.inc({ status: 'DONE' }, 0);

tasksCompletedCounter.inc({ status: 'DONE' }, 0);

userActivityCounter.inc({ action: 'list_tasks' }, 0);
userActivityCounter.inc({ action: 'create_task' }, 0);
userActivityCounter.inc({ action: 'update_task' }, 0);
userActivityCounter.inc({ action: 'delete_task' }, 0);

// ==========================================
// MIDDLEWARE
// ==========================================
app.use(cors());
app.use(express.json());

// Metrics Middleware: Starts a timer for every incoming request
app.use((req, res, next) => {
  if (req.path === '/metrics' || req.path === '/health') {
    return next();
  }
  const end = httpRequestDuration.startTimer();

  res.on('finish', () => {
    // We use req.route?.path to avoid cardinality explosion if a user hits random 404 paths
    const route = req.route ? req.route.path : req.path;
    end({
      method: req.method,
      route: route,
      status: res.statusCode
    });
  });
  
  next();
});

// ==========================================
// DATABASE CONFIGURATION
// ==========================================
const pool = new Pool({
  user: process.env.DB_USER || 'postgres',
  host: process.env.DB_HOST || 'localhost',
  database: process.env.DB_NAME || 'taskdb',
  password: process.env.DB_PASSWORD || 'postgres',
  port: process.env.DB_PORT || 5432,
});

// ==========================================
// ROUTES
// ==========================================

// GET: Health check endpoint
app.get('/health', (req, res) => {
  res.json({ status: 'healthy' });
});

// GET: Expose Prometheus metrics endpoint
app.get('/metrics', async (req, res) => {
  try {
    res.set('Content-Type', client.register.contentType);
    res.end(await client.register.metrics());
  } catch (err) {
    res.status(500).end(err);
  }
});

// GET: Get all tasks
app.get('/api/tasks', async (req, res) => {
  try {
    const result = await pool.query(
      'SELECT * FROM tasks ORDER BY created_at DESC'
    );
    userActivityCounter.inc({ action: 'list_tasks' });
    res.json(result.rows);
  } catch (err) {
    console.error('Error fetching tasks:', err);
    res.status(500).json({ error: 'Failed to fetch tasks' });
  }
});

// POST: Create a task
app.post('/api/tasks', async (req, res) => {
  const { title, description } = req.body;

  if (!title) {
    return res.status(400).json({ error: 'Title is required' });
  }

  try {
    const result = await pool.query(
      'INSERT INTO tasks (title, description) VALUES ($1, $2) RETURNING *',
      [title, description]
    );

    tasksCreatedCounter.inc({ status: result.rows[0].status });
    userActivityCounter.inc({ action: 'create_task' });

    res.status(201).json(result.rows[0]);
  } catch (err) {
    console.error('Error creating task:', err);
    res.status(500).json({ error: 'Failed to create task' });
  }
});

// PUT: Update a task
app.put('/api/tasks/:id', async (req, res) => {
  const { id } = req.params;
  const { title, description, status } = req.body;

  if (status && !['TODO', 'IN_PROGRESS', 'DONE'].includes(status)) {
    return res.status(400).json({ error: 'Invalid status. Use TODO, IN_PROGRESS, or DONE' });
  }

  try {
    const result = await pool.query(
      'UPDATE tasks SET title = COALESCE($1, title), description = COALESCE($2, description), status = COALESCE($3, status), updated_at = CURRENT_TIMESTAMP WHERE id = $4 RETURNING *',
      [title, description, status, id]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Task not found' });
    }

    const updatedTask = result.rows[0];
    if (updatedTask.status === 'DONE') {
      tasksCompletedCounter.inc({ status: 'DONE' });
    }
    userActivityCounter.inc({ action: 'update_task' });

    res.json(updatedTask);
  } catch (err) {
    console.error('Error updating task:', err);
    res.status(500).json({ error: 'Failed to update task' });
  }
});

// DELETE: Delete a task
app.delete('/api/tasks/:id', async (req, res) => {
  const { id } = req.params;

  try {
    const result = await pool.query(
      'DELETE FROM tasks WHERE id = $1 RETURNING *',
      [id]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Task not found' });
    }
    userActivityCounter.inc({ action: 'delete_task' });
    res.json({ message: 'Task deleted successfully' });
  } catch (err) {
    console.error('Error deleting task:', err);
    res.status(500).json({ error: 'Failed to delete task' });
  }
});

// Error handling middleware
app.use((err, req, res, next) => {
  console.error(err.stack);
  res.status(500).json({ error: 'Something broke!' });
});

// ==========================================
// SERVER LIFECYCLE & GRACEFUL SHUTDOWN
// ==========================================

// Start server
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});

// Handle SIGTERM/SIGINT for Kubernetes rolling deployments
const shutdown = (signal) => {
  console.log(`${signal} received: closing HTTP server...`);
  server.close(() => {
    console.log('HTTP server closed. Closing database pool...');
    pool.end(() => {
      console.log('Database pool closed. Exiting process.');
      process.exit(0);
    });
  });
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

module.exports = {
  app,
  client,
  metrics: {
    httpRequestDuration,
    tasksCreatedCounter,
    tasksCompletedCounter,
    userActivityCounter
  }
};
