#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

# Jenkins Java requirement moves roughly every year; if this JDK version
apt-get update -y
apt-get install -y python3 python3-pip python3-venv git curl fontconfig openjdk-21-jdk rsync awscli

curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs
npm install -g pm2

curl -fsSL -o /tmp/gitleaks.tar.gz \
  https://github.com/gitleaks/gitleaks/releases/download/v8.21.2/gitleaks_8.21.2_linux_x64.tar.gz
tar -xzf /tmp/gitleaks.tar.gz -C /usr/local/bin gitleaks
rm -f /tmp/gitleaks.tar.gz

# CloudWatch agent: EC2's free metrics don't cover memory/disk, this does.
curl -fsSL -o /tmp/amazon-cloudwatch-agent.deb \
  https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i /tmp/amazon-cloudwatch-agent.deb
rm -f /tmp/amazon-cloudwatch-agent.deb

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CWAGENT_EOF'
{
  "metrics": {
    "namespace": "${project_name}",
    "metrics_collected": {
      "mem": { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["used_percent"], "resources": ["/"] }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/user-data.log",
            "log_group_name": "/${project_name}/user-data",
            "log_stream_name": "{instance_id}"
          },
          {
            "file_path": "/var/log/jenkins/jenkins.log",
            "log_group_name": "/${project_name}/jenkins",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  }
}
CWAGENT_EOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

install -d -m 0755 /usr/share/keyrings
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key -o /usr/share/keyrings/jenkins-keyring.asc
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  | tee /etc/apt/sources.list.d/jenkins.list > /dev/null

apt-get update -y
apt-get install -y jenkins
systemctl enable jenkins
systemctl start jenkins

mkdir -p /opt/app
chown jenkins:jenkins /opt/app

sudo -u jenkins -H bash <<'JENKINS_USER_EOF'
set -euxo pipefail
cd /opt/app
git clone ${github_repo_url} .

cd /opt/app/backend
python3 -m venv venv
./venv/bin/pip install --no-cache-dir -r requirements.txt
# Repo hardcodes port 5001; assignment wants 5000. Jenkins reapplies this
# same patch on every deploy since a fresh checkout reverts it.
sed -i "s/port=5001/port=${backend_port}/" app.py

cd /opt/app/frontend
npm install --production

export MONGO_URI="$(aws secretsmanager get-secret-value \
  --secret-id "${mongo_secret_name}" \
  --region "${aws_region}" \
  --query SecretString --output text)"

cat > /opt/app/ecosystem.config.js <<'EOF'
module.exports = {
  apps: [
    {
      name: "flask-backend",
      script: "app.py",
      interpreter: "/opt/app/backend/venv/bin/python3",
      cwd: "/opt/app/backend",
      env: { MONGO_URI: process.env.MONGO_URI }
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

env PATH=$PATH:/usr/bin pm2 startup systemd -u jenkins --hp /var/lib/jenkins \
  | tail -n 1 | bash

sudo -u jenkins pm2 save
