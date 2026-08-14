<div align="center">

# Assignment 9: Jenkins CI/CD Deployment

</div>

## What I built and why

The assignment asks for two things: get Flask and Express running on one EC2 box, and get Jenkins automatically redeploying them on every push. I used Terraform for the EC2 part since I'd already been using it for the earlier assignments and didn't want a fourth different way of spinning up an instance in this repo.

I put both apps under pm2 instead of writing separate systemd unit files for each. pm2 is basically built for exactly this, keeping a couple of Node/Python processes alive, auto-restarting them on crash, and giving you a one-line restart command, which is what the Jenkins pipeline needs anyway (`pm2 restart flask-backend`). Systemd would work too, but it's more files and more syntax for the same result here.

## Folder layout

```
flask-app/
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── provider.tf
│   ├── versions.tf
│   ├── backend.tf
│   ├── templates/
│   │   └── user_data.sh.tpl
│   └── terraform.tfvars.example
├── Jenkinsfile.backend
├── Jenkinsfile.frontend
└── README.md
```

Jenkinsfile.backend and Jenkinsfile.frontend live at the repo root as actual files, not pasted into a writeup. Jenkins needs to check them out from source control and run them directly, which only works if they're real files at a real path.

## Part 1: EC2 instance

### The instance setup

The VPC, subnet, and the EC2 instance itself now come from the official `terraform-aws-modules/vpc/aws` and `terraform-aws-modules/ec2-instance/aws` registry modules, not hand-rolled resources, that was a rework after the first round of feedback specifically asked for it. A security group (kept as a plain resource, not a module, the ruleset is small enough that a module didn't buy much) opens SSH (my IP only), port 3000 (frontend), port 5000 (backend), and port 8080 (Jenkins). One `t3.medium` running Ubuntu 22.04.

I bumped it up from `t3.micro` to `t3.medium` on purpose. Free tier only covers micro, but Jenkins plus two running apps plus whatever Jenkins needs to actually do a build (installing pip/npm packages, running tests, now also Gitleaks/Bandit/pip-audit/npm audit) is more than a 1GB instance can handle without swapping constantly or just OOM-killing something mid-build. Costs a bit more, but the free-tier instance kept getting slow enough during builds that it wasn't worth fighting.

The instance also gets an IAM role now, scoped to exactly two things: reading one specific Secrets Manager secret (the Mongo URI, more on that below) and the standard `CloudWatchAgentServerPolicy` for shipping logs and metrics. Neither existed in the first version of this.

### The boot script

`user_data.sh.tpl` is what runs the first time the instance boots. It installs Python, Node, Java (Jenkins needs Java to run at all, it's a Java application under the hood), Jenkins itself, pm2, Gitleaks, and the CloudWatch agent. Then it clones the app repo and sets both apps up.

One thing that tripped me up here: the app's Flask backend has its port hardcoded to 5001 in `app.py`, but the assignment specifically wants port 5000. I didn't want to edit the actual app code just to satisfy this one assignment's port number, so instead the boot script runs a `sed` command that swaps `port=5001` for `port=5000` right after cloning, on the deployed copy only. The tradeoff is that this patch has to be reapplied every time the code gets redeployed (since a fresh `git clone` or `git pull` would just bring back the original 5001), so the same `sed` line shows up again in the Jenkins pipeline for the backend.

The other thing worth explaining is why everything after the Jenkins install runs as the `jenkins` Linux user specifically, instead of root. pm2 tracks running processes per user, it's basically a separate list for each person logged in. If I'd started the apps as root during the initial boot, then later had a Jenkins job (which runs as the `jenkins` user) try to run `pm2 restart flask-backend`, that command would be looking at the `jenkins` user's process list, which would be empty, since the process actually belongs to root's list. It would just fail with "process not found," not because the app isn't running, but because pm2 is checking the wrong bucket. Running the whole setup as `jenkins` from the start avoids that entirely.

### The Mongo credential

This one got flagged twice in feedback and I want to be straight about what actually changed. Originally `app.py` had a hardcoded fallback connection string baked into the file itself, so even if `MONGO_URI` was never set anywhere, the app would silently connect using that default. That's gone now, `app.py` raises an error at startup if `MONGO_URI` isn't set, no silent fallback.

Where the real value lives now: AWS Secrets Manager, not Terraform, not any committed file. Terraform creates an empty secret container, the actual value gets set once manually with `aws secretsmanager put-secret-value`, a command that never touches this repo or Terraform's state. At boot, the instance fetches it itself using that IAM role mentioned above, scoped to read exactly that one secret and nothing else in the account.

What this doesn't fix: the credential that was already committed to git history in earlier commits is still compromised regardless of what the code looks like now, editing files doesn't undo past commits. That password needs to actually get rotated in Atlas, which is a manual step outside of anything Terraform or Jenkins does.

### Things that broke while setting this up

I'm including these because they're the actual bugs I hit, not made-up ones.

**Jenkins wouldn't install, `NO_PUBKEY` error on `apt-get update`.** Jenkins signs its apt repo with a key, and that key gets rotated occasionally. The URL in my script was pointing at an old key file that no longer matched what the repo was actually signed with. Fixed by grabbing the current key URL from Jenkins' own install docs.

**Jenkins installed fine but wouldn't start, `systemctl start jenkins` failed.** Checked `journalctl -xeu jenkins.service` and it came down to a Java version problem, the Jenkins version that got installed needed a newer JDK than what my script installed. Bumped from Java 17 to Java 21 and it started fine after that.

**First Jenkins build failed immediately with `fatal: couldn't find remote ref refs/heads/master`.** My Jenkins job was configured to look for a branch called `master`, but the actual repo's default branch is `main`. Easy fix once I saw the error, just had to change the branch name in the job config, but it's the kind of thing that's obvious in hindsight and not obvious beforehand if you're used to `master` being the default (it hasn't been GitHub's default for new repos in a while now).

I'm mentioning all three of these because I think they're actually the more useful part of doing this assignment. The Terraform and Jenkinsfile code isn't that complicated once it's working, but none of these three problems show up until you actually try to run it against real infrastructure, and figuring out which log to check and what the error actually meant was most of the real work.

### Running it

```bash
cd terraform
terraform init
terraform plan
terraform apply -var-file=terraform.tfvars
```

![terraform apply running](./Screenshots/Terraform-1.png)

![terraform apply finished, outputs shown](./Screenshots/Terraform-1.1.png)

`terraform.tfvars` needs `key_name` and `allowed_ssh_cidr` set to real values, and `mongo_uri` set to the real Atlas connection string. None of these have defaults on purpose, mostly so I don't accidentally commit a real value into `variables.tf`, which does get pushed to GitHub. `terraform.tfvars` itself is gitignored.

## Part 2: Jenkins setup

This part is manual, Terraform installs Jenkins but doesn't configure it.

1. SSH in, grab the initial admin password:
   ```bash
   ssh -i <path-to-key>.pem ubuntu@<instance-ip>
   sudo cat /var/lib/jenkins/secrets/initialAdminPassword
   ```
2. Open `http://<instance-ip>:8080` and paste it in.
3. Installed the suggested plugins. There isn't really a dedicated "Python plugin" the way there's a NodeJS plugin, Jenkins just runs `python3` and `pip` as shell commands, so as long as they're on the system PATH (which the boot script already handles), that's all Jenkins needs.
4. Made two separate pipeline jobs, both pulling from the same repo, one running `Jenkinsfile.backend`, the other `Jenkinsfile.frontend`.
5. Added a GitHub webhook pointing at `http://<instance-ip>:8080/github-webhook/`. The trailing slash actually matters, I left it off the first time and the webhook showed as "delivered" on GitHub's side but nothing happened in Jenkins, because it was hitting the wrong path.

### Jenkinsfile.backend

```groovy
// index.lock race if both pipelines run close together.
pipeline {
    agent any

    triggers {
        githubPush()
    }

    environment {
        DEPLOY_DIR = '/opt/app/backend'
        BACKUP_DIR = '/opt/app/backend.backup'
        BACKEND_PORT = '5000'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Backup current live version') {
            steps {
                sh '''
                    if [ -d "$DEPLOY_DIR" ]; then
                        rm -rf "$BACKUP_DIR"
                        cp -a "$DEPLOY_DIR" "$BACKUP_DIR"
                    fi
                '''
            }
        }

        stage('Sync to deploy path') {
            steps {
                sh 'rsync -a --delete --exclude venv backend/ $DEPLOY_DIR/'
            }
        }

        stage('Install Dependencies') {
            steps {
                dir("${env.DEPLOY_DIR}") {
                    sh '''
                        if [ ! -d venv ]; then
                            python3 -m venv venv
                        fi
                        ./venv/bin/pip install --no-cache-dir -r requirements.txt
                        ./venv/bin/pip install --no-cache-dir pytest bandit pip-audit
                    '''
                }
            }
        }

        stage('Patch Port') {
            steps {
                dir("${env.DEPLOY_DIR}") {
                    sh "sed -i 's/port=5001/port=5000/' app.py"
                }
            }
        }

        stage('Security Scan') {
            steps {
                dir("${env.DEPLOY_DIR}") {
                    // Gitleaks blocks the build. Bandit/pip-audit report only.
                    sh 'gitleaks detect --source . --no-git -v'
                    sh './venv/bin/bandit -r . -x ./venv,./tests || true'
                    sh './venv/bin/pip-audit || true'
                }
            }
        }

        stage('Test') {
            steps {
                dir("${env.DEPLOY_DIR}") {
                    sh './venv/bin/pytest -v'
                }
            }
        }

        stage('Restart via pm2') {
            steps {
                sh 'pm2 restart flask-backend'
            }
        }

        stage('Health Check') {
            steps {
                // Empty POST, expect Flask's own 400 -- confirms the
                // process is up without writing junk data to prod Mongo.
                sh '''
                    sleep 3
                    STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
                      -X POST http://localhost:$BACKEND_PORT/api/submit \
                      -H "Content-Type: application/json" -d '{}')
                    if [ "$STATUS" != "400" ]; then
                        echo "Health check failed: expected 400, got $STATUS"
                        exit 1
                    fi
                '''
            }
        }
    }

    post {
        failure {
            sh '''
                if [ -d "$BACKUP_DIR" ]; then
                    echo "Rolling back to previous version"
                    rm -rf "$DEPLOY_DIR"
                    mv "$BACKUP_DIR" "$DEPLOY_DIR"
                    pm2 restart flask-backend || true
                else
                    echo "No backup to roll back to, this was the first deploy."
                fi
            '''
        }
        success {
            sh 'rm -rf "$BACKUP_DIR"'
        }
    }
}
```

Jenkins checks out the whole monorepo into its own workspace, then `rsync` copies just the `backend/` folder into `/opt/app/backend`, where pm2 is actually watching. I did it this way instead of pointing Jenkins' workspace directly at `/opt/app` because the frontend pipeline needs its own separate checkout too, and having both jobs check out into the same folder at the same time felt like asking for a git lock conflict if two pushes land close together. Keeping them in separate workspaces and only syncing the relevant subfolder avoids that.

The venv gets excluded from the rsync `--delete` so it doesn't get wiped and rebuilt from scratch on every single deploy, that would work but it's slower than it needs to be. The Install Dependencies step checks if the venv already exists before creating a new one.

This version has real tests now (`backend/tests/test_app.py`, pytest, mocking the actual database call so it doesn't need a live Mongo connection to run in CI), a hard-blocking Gitleaks scan before anything deploys (given this project's own history with a leaked credential, that's not hypothetical), Bandit and pip-audit running as report-only advisory scans, and a health check after the restart that POSTs an empty body and expects Flask's own 400 back, proving the process actually came back up without writing junk data into the real database on every deploy. If anything in the pipeline fails, from a bad test to a failed health check, the `post { failure {...} }` block restores whatever was running before (code and its installed dependencies both, backed up right at the start of the pipeline) and restarts pm2, instead of just logging that the old version is still running and leaving it at that.

![backend job build history in Jenkins](./Screenshots/Backend-Job.png)

### Jenkinsfile.frontend

```groovy
// a shared one, and how the backup/rollback pattern works.
pipeline {
    agent any

    triggers {
        githubPush()
    }

    environment {
        DEPLOY_DIR = '/opt/app/frontend'
        BACKUP_DIR = '/opt/app/frontend.backup'
        FRONTEND_PORT = '3000'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Backup current live version') {
            steps {
                sh '''
                    if [ -d "$DEPLOY_DIR" ]; then
                        rm -rf "$BACKUP_DIR"
                        cp -a "$DEPLOY_DIR" "$BACKUP_DIR"
                    fi
                '''
            }
        }

        stage('Sync to deploy path') {
            steps {
                sh 'rsync -a --delete --exclude node_modules frontend/ $DEPLOY_DIR/'
            }
        }

        stage('Install Dependencies') {
            steps {
                dir("${env.DEPLOY_DIR}") {
                    sh 'npm install'
                }
            }
        }

        stage('Security Scan') {
            steps {
                dir("${env.DEPLOY_DIR}") {
                    sh 'gitleaks detect --source . --no-git -v'
                    sh 'npm audit || true'
                }
            }
        }

        stage('Test') {
            steps {
                dir("${env.DEPLOY_DIR}") {
                    sh 'npx jest --ci'
                }
            }
        }

        stage('Prune to production deps') {
            steps {
                dir("${env.DEPLOY_DIR}") {
                    sh 'npm prune --production'
                }
            }
        }

        stage('Restart via pm2') {
            steps {
                sh 'pm2 restart express-frontend'
            }
        }

        stage('Health Check') {
            steps {
                sh '''
                    sleep 3
                    STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$FRONTEND_PORT/)
                    if [ "$STATUS" != "200" ]; then
                        echo "Health check failed: expected 200, got $STATUS"
                        exit 1
                    fi
                '''
            }
        }
    }

    post {
        failure {
            sh '''
                if [ -d "$BACKUP_DIR" ]; then
                    echo "Rolling back to previous version"
                    rm -rf "$DEPLOY_DIR"
                    mv "$BACKUP_DIR" "$DEPLOY_DIR"
                    pm2 restart express-frontend || true
                else
                    echo "No backup to roll back to, this was the first deploy."
                fi
            '''
        }
        success {
            sh 'rm -rf "$BACKUP_DIR"'
        }
    }
}
```

Same idea as the backend one, no port patch needed since Express is already on the right port (3000) by default in this repo. Real tests now too (`frontend/tests/server.test.js`, Jest + Supertest, with `axios` mocked so it doesn't need a real backend running to test against), which needed one small change to `server.js` first, exporting the Express `app` object and guarding `app.listen()` behind `require.main === module`, since it previously called `.listen()` unconditionally and wasn't importable for testing at all. Same Gitleaks/npm-audit scan pattern, same backup-and-restore rollback on failure, same health check idea, just checking port 3000 answers with a 200 instead of checking Flask's validation response.

![frontend job build history in Jenkins](./Screenshots/Frontend-Job.png)

### GitHub webhook

Repo Settings, Webhooks, Add webhook, Payload URL `http://<instance-ip>:8080/github-webhook/`, content type `application/json`, trigger on push.

![adding the webhook in GitHub](./Screenshots/Webhook.png)

![webhook showing a successful delivery](./Screenshots/Webhook-1.1.png)

![webhook recent deliveries log](./Screenshots/Webhook-1.2.png)

## What I'd still want to fix

I'm not going to pretend this setup is production ready, because it isn't, and I think that's fine for what this assignment is asking for, but worth being upfront about what's actually still open versus what got fixed in the second pass:

- Everything, Jenkins, the frontend, and the backend, lives on one instance. If that instance runs out of disk from Jenkins build history, or Jenkins itself crashes, the live apps go down with it. In a real setup I'd want the CI runner separate from wherever the app actually runs. Still true, didn't touch this.
- Jenkins' login page is open to the whole internet on port 8080, since the GitHub webhook needs a way to reach it. Still true, still not solved, just something I'm aware of.
- Rollback is real now, not just documented as missing. Each pipeline backs up the currently-running version (code and its installed dependencies) before deploying, and restores it automatically if any stage fails, tests, the security scan, or the health check after restart. What this doesn't cover: a bad deploy that passes every check but is still wrong in some way none of them test for. No automated system here would catch that, someone still has to notice.
- Security scanning is in the pipeline now too, Gitleaks as a hard gate (given this project already had a real credential leak, that's not a hypothetical risk), Bandit/pip-audit/npm audit as advisory reports that don't block the build.
- Monitoring exists now (CloudWatch agent shipping memory/disk metrics and the boot + Jenkins logs), but there's no alerting attached to any of it. Something can go visibly wrong in CloudWatch and nothing pages anyone, I'd still have to go looking.
- The port patch (`sed`ing 5001 to 5000) happens in two places now, the boot script and the backend Jenkinsfile, because both need it independently. If that exact line in `app.py` ever gets rewritten slightly, the sed just quietly stops matching and does nothing, no error, the app just comes up on the wrong port with no obvious explanation. The actual fix would be reading the port from an environment variable in the app itself instead of patching around it after the fact, I just didn't want to change the app code for a one-off assignment requirement.

<div align="center">

## Project screenshots

</div>

![app running end to end](./Screenshots/Project-ss-1.png)

![app running end to end, second view](./Screenshots/Project-ss-2.png)
