#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

# --- Base dependencies ---
apt-get update -y
apt-get install -y python3 python3-pip python3-venv git curl fontconfig openjdk-21-jdk rsync

curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs
npm install -g pm2

# --- Jenkins ---
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key -o /usr/share/keyrings/jenkins-keyring.asc
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  | tee /etc/apt/sources.list.d/jenkins.list > /dev/null

apt-get update -y
apt-get install -y jenkins
systemctl enable jenkins
systemctl start jenkins

# --- App deploy, all as the jenkins user ---
# Everything below runs as `jenkins` (not root) so that the pm2 daemon
# Jenkins pipeline jobs later talk to via `pm2 restart <app>` is the SAME
mkdir -p /opt/app
chown jenkins:jenkins /opt/app

sudo -u jenkins -H bash <<'JENKINS_USER_EOF'
set -euxo pipefail
cd /opt/app
git clone ${github_repo_url} .

# Backend: venv + deps
cd /opt/app/backend
python3 -m venv venv
./venv/bin/pip install --no-cache-dir -r requirements.txt
# Repo hardcodes port 5001; this assignment wants 5000. Patched here on
# initial boot; the Jenkins pipeline re-applies the same sed after every
# future `git pull`, since a fresh checkout would otherwise revert it.
sed -i "s/port=5001/port=${backend_port}/" app.py

# Frontend: npm deps
cd /opt/app/frontend
npm install --production

# pm2 process definitions -- single source of truth both this initial
# boot AND every Jenkins-triggered restart reference by name.
cat > /opt/app/ecosystem.config.js <<EOF
module.exports = {
  apps: [
    {
      name: "flask-backend",
      script: "app.py",
      interpreter: "/opt/app/backend/venv/bin/python3",
      cwd: "/opt/app/backend",
      env: { MONGO_URI: "${mongo_uri}" }
    },
    {
      name: "express-frontend",
      script: "server.js",
      cwd: "/opt/app/frontend",
      env: { BACKEND_URL: "http://localhost:${backend_port}/api/submit", PORT: "${frontend_port}" }
    }
  ]
}
EOF

pm2 start /opt/app/ecosystem.config.js
pm2 save
JENKINS_USER_EOF

# pm2 startup script -- makes both apps survive a reboot, as `jenkins` user
env PATH=$PATH:/usr/bin pm2 startup systemd -u jenkins --hp /var/lib/jenkins \
  | tail -n 1 | bash

sudo -u jenkins pm2 save
