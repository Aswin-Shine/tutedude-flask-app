# Assignment-5 — Dockerized Full-Stack App

A full-stack web application containerized with Docker and orchestrated via Docker Compose. Users submit a form through a Node.js/Express frontend, which forwards the data to a Python/Flask backend that persists it to a MongoDB Atlas cluster.

---

## Architecture

```
Browser
  └── Frontend (Node.js + Express + EJS)  :3000
        └── HTTP POST via Axios
              └── Backend (Python + Flask)  :5001
                    └── MongoDB Atlas (Cloud)
```

All services communicate over a custom Docker bridge network (`devops_bridge_net`). The frontend reaches the backend using Docker Compose's internal DNS (`http://backend:5001`).

---

## Project Structure

```
Assignment-5-app/
├── docker-compose.yml
├── backend/
│   ├── Dockerfile
│   ├── app.py
│   └── requirements.txt
└── frontend/
    ├── Dockerfile
    ├── package.json
    ├── server.js
    └── views/
        └── form.ejs
```

---

## Frontend

**Stack:** Node.js 18, Express, EJS, Axios

The frontend is a lightweight Express server that renders an EJS form. On submission it proxies the payload to the Flask backend via Axios and displays either a success message or an inline error.

| File         | Purpose                                      |
|--------------|----------------------------------------------|
| `server.js`  | Express server, routes `GET /` and `POST /submit` |
| `views/form.ejs` | HTML form — collects username and email  |
| `package.json` | Dependencies: express, ejs, axios          |
| `Dockerfile` | Node 18 Alpine image, exposes port 3000      |

**Key environment variable:**

| Variable       | Default                             | Description                        |
|----------------|-------------------------------------|------------------------------------|
| `BACKEND_URL`  | `http://backend:5001/api/submit`    | Internal Docker DNS to Flask API   |

**Routes:**

| Method | Path      | Description                                 |
|--------|-----------|---------------------------------------------|
| GET    | `/`       | Renders the submission form                 |
| POST   | `/submit` | Forwards form data to the Flask backend     |

---

## Backend

**Stack:** Python 3.10, Flask, Flask-CORS, PyMongo, DNSPython

The backend exposes a single REST endpoint that receives JSON, validates the fields, and inserts the document into a MongoDB Atlas collection (`tutedude_devops.submissions`).

| File               | Purpose                                             |
|--------------------|-----------------------------------------------------|
| `app.py`           | Flask app with `/api/submit` POST endpoint          |
| `requirements.txt` | Dependencies: flask, flask-cors, pymongo, dnspython |
| `Dockerfile`       | Python 3.10-slim image, exposes port 5001           |

**Key environment variable:**

| Variable    | Description                        |
|-------------|------------------------------------|
| `MONGO_URI` | MongoDB Atlas connection string    |

**API Endpoint — `POST /api/submit`**

Request body:
```json
{
  "username": "john_doe",
  "email": "john@example.com"
}
```

Success response `200`:
```json
{ "success": true, "message": "Data processed successfully" }
```

Error response `400`:
```json
{ "success": false, "error": "Missing required data fields" }
```

---

## Service Ports

| Service  | Host Port | Container Port |
|----------|-----------|----------------|
| Frontend | 3000      | 3000           |
| Backend  | 5001      | 5001           |

---

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running

```bash
docker --version
docker compose version
```

---

## Docker Commands

**Build and start all services:**
```bash
docker compose up -d --build
```

**Stop and remove containers:**
```bash
docker compose down
```

**View logs:**
```bash
docker compose logs -f
```

**Check running containers:**
```bash
docker compose ps
```

**Rebuild a single service:**
```bash
docker compose build backend
docker compose build frontend
```

**Tag and push images to Docker Hub:**
```bash
docker tag devops-flask-backend <your-dockerhub-username>/devops-flask-backend:latest
docker push <your-dockerhub-username>/devops-flask-backend:latest

docker tag devops-node-frontend <your-dockerhub-username>/devops-node-frontend:latest
docker push <your-dockerhub-username>/devops-node-frontend:latest
```

---

## Running the App

```bash
# 1. Navigate to the app directory
cd Assignment-5/Assignment-5-app

# 2. Build and start
docker compose up -d --build

# 3. Open in browser
http://localhost:3000
```

Fill in the form with a username and email — the data gets saved to MongoDB Atlas.
