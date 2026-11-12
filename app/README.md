# Task Manager Application

## Components

### Frontend (React)
- Task management interface
- Create, edit, delete tasks
- Update task status
- React hooks and components

### Backend (Node.js)
- REST API endpoints
- PostgreSQL database connection
- Express.js framework
- Basic error handling

### Database (PostgreSQL)
- Tasks table
- Basic CRUD operations
- Simple schema

## Local Development

1. Start all services:
```bash
docker compose up
```

2. Access the application:
- Frontend: http://localhost:3000 (React dev server)
- Backend API: http://localhost:3001

## Project Structure
```
.
├── frontend/           # React application
│   ├── src/           # React components
│   ├── Dockerfile     # Frontend container
│   └── package.json   # Dependencies
├── backend/           # Node.js API
│   ├── src/           # API endpoints
│   ├── Dockerfile     # Backend container
│   └── package.json   # Dependencies
└── database/          # PostgreSQL setup
    └── init.sql       # Database schema
```

## Environment Setup

### Frontend (.env)
```
REACT_APP_API_URL=http://localhost:3001/api
```

### Backend (.env)
```
NODE_ENV=development
PORT=3000
DB_HOST=postgres
DB_PORT=5432
DB_NAME=taskdb
DB_USER=postgres
DB_PASSWORD=postgres
```

## Basic Commands

### Start Application
```bash
# Start all services
docker compose up

# Start in background
docker compose up -d
```

### Development
```bash
# Local development with Docker (recommended)
docker compose up -d

# Manual development setup (alternative)
# Frontend development
cd frontend
npm install
npm start  # Runs on http://localhost:3000

# Backend development
cd backend
npm install
npm run dev  # Runs on http://localhost:3001
```