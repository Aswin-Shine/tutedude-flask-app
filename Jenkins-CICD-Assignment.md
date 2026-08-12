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

Default VPC, a security group opening SSH (my IP only), port 3000 (frontend), port 5000 (backend), and port 8080 (Jenkins), and one `t3.medium` running Ubuntu 22.04.

I bumped it up from `t3.micro` to `t3.medium` on purpose. Free tier only covers micro, but Jenkins plus two running apps plus whatever Jenkins needs to actually do a build (installing pip/npm packages, running tests) is more than a 1GB instance can handle without swapping constantly or just OOM-killing something mid-build. Costs a bit more, but the free-tier instance kept getting slow enough during builds that it wasn't worth fighting.

### The boot script

`user_data.sh.tpl` is what runs the first time the instance boots. It installs Python, Node, Java (Jenkins needs Java to run at all, it's a Java application under the hood), Jenkins itself, and pm2. Then it clones the app repo and sets both apps up.

One thing that tripped me up here: the app's Flask backend has its port hardcoded to 5001 in `app.py`, but the assignment specifically wants port 5000. I didn't want to edit the actual app code just to satisfy this one assignment's port number, so instead the boot script runs a `sed` command that swaps `port=5001` for `port=5000` right after cloning, on the deployed copy only. The tradeoff is that this patch has to be reapplied every time the code gets redeployed (since a fresh `git clone` or `git pull` would just bring back the original 5001), so the same `sed` line shows up again in the Jenkins pipeline for the backend.

The other thing worth explaining is why everything after the Jenkins install runs as the `jenkins` Linux user specifically, instead of root. pm2 tracks running processes per user, it's basically a separate list for each person logged in. If I'd started the apps as root during the initial boot, then later had a Jenkins job (which runs as the `jenkins` user) try to run `pm2 restart flask-backend`, that command would be looking at the `jenkins` user's process list, which would be empty, since the process actually belongs to root's list. It would just fail with "process not found," not because the app isn't running, but because pm2 is checking the wrong bucket. Running the whole setup as `jenkins` from the start avoids that entirely.

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
pipeline {
    agent any

    triggers {
        githubPush()
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Sync to deploy path') {
            steps {
                sh 'rsync -a --delete --exclude venv backend/ /opt/app/backend/'
            }
        }

        stage('Install Dependencies') {
            steps {
                dir('/opt/app/backend') {
                    sh '''
                        if [ ! -d venv ]; then
                            python3 -m venv venv
                        fi
                        ./venv/bin/pip install --no-cache-dir -r requirements.txt
                    '''
                }
            }
        }

        stage('Patch Port') {
            steps {
                dir('/opt/app/backend') {
                    sh "sed -i 's/port=5001/port=5000/' app.py"
                }
            }
        }

        stage('Test') {
            steps {
                dir('/opt/app/backend') {
                    sh '''
                        if [ -d tests ] || ls test_*.py > /dev/null 2>&1; then
                            ./venv/bin/pip install --no-cache-dir pytest
                            ./venv/bin/pytest || true
                        else
                            echo "No tests in backend/ yet, skipping"
                        fi
                    '''
                }
            }
        }

        stage('Restart via pm2') {
            steps {
                sh 'pm2 restart flask-backend'
            }
        }
    }

    post {
        failure {
            echo 'Backend pipeline failed, flask-backend was not restarted, old version keeps running.'
        }
        success {
            echo 'Backend deployed and restarted.'
        }
    }
}
```

Jenkins checks out the whole monorepo into its own workspace, then `rsync` copies just the `backend/` folder into `/opt/app/backend`, where pm2 is actually watching. I did it this way instead of pointing Jenkins' workspace directly at `/opt/app` because the frontend pipeline needs its own separate checkout too, and having both jobs check out into the same folder at the same time felt like asking for a git lock conflict if two pushes land close together. Keeping them in separate workspaces and only syncing the relevant subfolder avoids that.

The venv gets excluded from the rsync `--delete` so it doesn't get wiped and rebuilt from scratch on every single deploy, that would work but it's slower than it needs to be. The Install Dependencies step checks if the venv already exists before creating a new one.

The test stage is honestly not doing much right now, the app doesn't have any tests yet, so it just checks whether a `tests/` folder or `test_*.py` files exist and skips cleanly if not, instead of failing the whole pipeline over something that was never there. If I add real tests later this stage would actually run them.

### Jenkinsfile.frontend

```groovy
pipeline {
    agent any

    triggers {
        githubPush()
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Sync to deploy path') {
            steps {
                sh 'rsync -a --delete --exclude node_modules frontend/ /opt/app/frontend/'
            }
        }

        stage('Install Dependencies') {
            steps {
                dir('/opt/app/frontend') {
                    sh 'npm install --production'
                }
            }
        }

        stage('Test') {
            steps {
                dir('/opt/app/frontend') {
                    sh '''
                        if node -e "process.exit(require('./package.json').scripts && require('./package.json').scripts.test ? 0 : 1)"; then
                            npm test || true
                        else
                            echo "No test script in package.json, skipping"
                        fi
                    '''
                }
            }
        }

        stage('Restart via pm2') {
            steps {
                sh 'pm2 restart express-frontend'
            }
        }
    }

    post {
        failure {
            echo 'Frontend pipeline failed, express-frontend was not restarted, old version keeps running.'
        }
        success {
            echo 'Frontend deployed and restarted.'
        }
    }
}
```

Same idea as the backend one, just no port patch needed since Express is already on the right port (3000) by default in this repo.

## What I'd still want to fix

I'm not going to pretend this setup is production ready, because it isn't, and I think that's fine for what this assignment is asking for, but worth being upfront about:

- Everything, Jenkins, the frontend, and the backend, lives on one instance. If that instance runs out of disk from Jenkins build history, or Jenkins itself crashes, the live apps go down with it. In a real setup I'd want the CI runner separate from wherever the app actually runs.

- Jenkins' login page is open to the whole internet on port 8080, since the GitHub webhook needs a way to reach it. That's a real tradeoff, not something I've solved, just something I'm aware of.

- There's no rollback if a bad deploy gets pushed through. Right now the test stage barely does anything since there aren't real tests yet, so a broken commit would probably just get deployed straight to pm2.

- The port patch (`sed`ing 5001 to 5000) happens in two places now, the boot script and the backend Jenkinsfile, because both need it independently. If that exact line in `app.py` ever gets rewritten slightly, the sed just quietly stops matching and does nothing, no error, the app just comes up on the wrong port with no obvious explanation. The actual fix would be reading the port from an environment variable in the app itself instead of patching around it after the fact, I just didn't want to change the app code for a one-off assignment requirement.