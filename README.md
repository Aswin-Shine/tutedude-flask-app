# Tutedude Flask App

A full-stack app with a Node/Express frontend and a Python/Flask backend, backed by MongoDB Atlas. Users fill in a form on the frontend, the frontend forwards it to the backend over HTTP, and the backend writes it to Atlas.

The app itself is small. What's in this repo is really three different ways to run it: locally with Docker Compose, on a Kubernetes cluster, or fully automated on AWS EC2 with Jenkins doing continuous deployment. Each of those lives in its own part of the repo and doesn't depend on the others.

## Architecture

```
Browser
  --> Frontend (Node.js + Express + EJS)   :3000
        --> HTTP POST via Axios
              --> Backend (Python + Flask)  :5001 (or :5000, see note below)
                    --> MongoDB Atlas (cloud, external to all of this)
```

MongoDB Atlas isn't part of this repo's infrastructure. It's a separate cloud cluster the backend connects to over the internet with a connection string.

A note on ports: the backend's code hardcodes port 5001. The Docker Compose and Kubernetes setups use that as-is. The Terraform/Jenkins EC2 deployment patches the running copy to port 5000 instead, since that's what that specific assignment required, without changing the actual `app.py` in this repo. If you're running this locally or on Kubernetes, it's on 5001. If you're running it through the Terraform setup, it's on 5000.

## Project structure

```
.
├── backend/                      Flask API
│   ├── app.py
│   ├── requirements.txt
│   └── Dockerfile
├── frontend/                     Express frontend
│   ├── server.js
│   ├── package.json
│   ├── views/form.ejs
│   └── Dockerfile
├── docker-compose.yml            run both locally with one command
├── k8s/                          Kubernetes manifests
│   ├── backend-deployment.yaml
│   ├── backend-service.yaml
│   ├── frontend-deployment.yaml
│   └── frontend-service.yaml
├── terraform/                    provisions a single EC2 instance running both apps + Jenkins
│   ├── main.tf, variables.tf, outputs.tf, provider.tf, versions.tf, backend.tf
│   ├── templates/user_data.sh.tpl
│   └── terraform.tfvars.example
├── Jenkins/
│   ├── Jenkinsfile.backend
│   └── Jenkinsfile.frontend
└── README.md                     this file
```

## Frontend

**Stack:** Node.js 18, Express, EJS, Axios

A small Express server that renders a form and, on submit, forwards the data to the Flask backend with Axios.

| File | Purpose |
|---|---|
| `server.js` | Express app, routes `GET /` and `POST /submit` |
| `views/form.ejs` | The actual form, collects username and email |
| `package.json` | Dependencies: express, ejs, axios |
| `Dockerfile` | Node 18, exposes port 3000 |

**Environment variable:**

| Variable | Default | What it's for |
|---|---|---|
| `BACKEND_URL` | `http://backend:5001/api/submit` | Where the frontend sends form submissions. The default assumes Docker Compose's internal DNS, this gets overridden in the Kubernetes and Terraform setups since the backend isn't reachable at that hostname in either of those. |

**Routes:**

| Method | Path | What it does |
|---|---|---|
| GET | `/` | Renders the form |
| POST | `/submit` | Forwards the submitted data to the Flask API |

## Backend

**Stack:** Python 3.10, Flask, Flask-CORS, PyMongo, DNSPython

One route that takes JSON, checks the required fields are present, and inserts the document into MongoDB Atlas.

| File | Purpose |
|---|---|
| `app.py` | The Flask app, single `/api/submit` POST endpoint |
| `requirements.txt` | flask, flask-cors, pymongo, dnspython |
| `Dockerfile` | Python 3.10-slim, exposes port 5001 |

**Environment variable:**

| Variable | Description |
|---|---|
| `MONGO_URI` | MongoDB Atlas connection string |

Worth knowing: `app.py` has a hardcoded fallback value for `MONGO_URI` if the environment variable isn't set (`os.getenv("MONGO_URI", "<the actual connection string>")`). That's why the Kubernetes deployment works even though `backend-deployment.yaml` doesn't set `MONGO_URI` anywhere, it just falls through to the hardcoded default. It's convenient for getting something running quickly, but it does mean the real database credential lives directly in source control, not just in a `.env` file or a secret. If this app went anywhere near production, that fallback is the first thing to remove, along with rotating that password since it's currently sitting in plain text in this repo's history.

**`POST /api/submit`**

Request:
```json
{
  "username": "john_doe",
  "email": "john@example.com"
}
```

Success (`200`):
```json
{ "success": true, "message": "Data processed successfully" }
```

Error (`400`, missing fields):
```json
{ "success": false, "error": "Missing required data fields" }
```

## Option 1: Run it locally with Docker Compose

The fastest way to just see the app working.

```bash
docker compose up -d --build
```

Then open `http://localhost:3000`. Frontend and backend talk to each other over Compose's internal network (`devops_bridge_net`), the frontend reaches the backend at `http://backend:5001`.

```bash
docker compose logs -f              # watch logs
docker compose ps                   # check what's running
docker compose down                 # stop and remove containers
docker compose build backend        # rebuild just one service
```

Pushing images somewhere else (Docker Hub, in this case):
```bash
docker tag devops-flask-backend <your-dockerhub-username>/devops-flask-backend:latest
docker push <your-dockerhub-username>/devops-flask-backend:latest

docker tag devops-node-frontend <your-dockerhub-username>/devops-node-frontend:latest
docker push <your-dockerhub-username>/devops-node-frontend:latest
```

## Option 2: Run it on Kubernetes

The `k8s/` folder has four manifests, one Deployment and one Service per app.

| File | What it is |
|---|---|
| `backend-deployment.yaml` | 1 replica, pulls `aswinshine/flask-backend:v1` from Docker Hub, listens on 5001 |
| `backend-service.yaml` | `ClusterIP`, internal only, not reachable from outside the cluster |
| `frontend-deployment.yaml` | 1 replica, pulls `aswinshine/node-frontend:v1`, sets `BACKEND_URL` to `http://backend-service:5001/api/submit` |
| `frontend-service.yaml` | `NodePort`, exposed on port `30080` on every node in the cluster |

Apply all four:
```bash
kubectl apply -f k8s/
```

Then hit `http://<any-node-ip>:30080` to reach the frontend. The backend is deliberately not exposed outside the cluster, `ClusterIP` means only things inside the cluster (like the frontend pod) can reach it, which is the right call for an internal API that doesn't need to be public.

This assumes you already have a cluster to point `kubectl` at, minikube, kind, or a real managed cluster like EKS. These manifests don't create one.

Both images here are pulled from Docker Hub, not ECR, that's a different registry from the one used in the Terraform/ECS setup mentioned below, if you're also working through that assignment. They're unrelated to each other.

## Option 3: Full EC2 deployment with Jenkins CI/CD

This is the more involved setup: Terraform provisions a single EC2 instance that runs Jenkins alongside both apps (managed by pm2 instead of Docker here), and Jenkins automatically redeploys either app whenever new code is pushed to GitHub.

This is documented in full detail, including troubleshooting for the actual issues hit while building it, in the CI/CD assignment's own README (`terraform/` and `Jenkins/` in this repo are the real files that setup depends on). Short version:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: key_name, allowed_ssh_cidr, mongo_uri at minimum
terraform init
terraform validate
terraform apply
```

This gives you a running EC2 instance with Jenkins on port 8080, the Express frontend on 3000, and the Flask backend on 5000 (patched from its default 5001, see the ports note above). Jenkins itself needs a few minutes of manual setup through its web UI afterward (initial admin password, plugin install, creating the two pipeline jobs, wiring up the GitHub webhook), none of that is scriptable through Terraform, it's a one-time click-through.

Once that's done, `git push` to this repo triggers `Jenkinsfile.backend` and `Jenkinsfile.frontend` to redeploy whichever app changed, using `pm2 restart` rather than rebuilding containers, this deployment path doesn't use Docker at all, unlike Options 1 and 2.

## Which option should you actually use

- Just want to see the app run: Docker Compose.
- Testing how it behaves on a real orchestrator, or already have a cluster: Kubernetes.
- Need the actual CI/CD pipeline (the point of the Jenkins assignment): the Terraform/Jenkins setup. This one's also the only one of the three that isn't using Docker, everything runs as native processes under pm2 instead.

They don't share infrastructure or state, running one doesn't affect or require the others.