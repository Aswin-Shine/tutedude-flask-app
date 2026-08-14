output "instance_public_ip" {
  value = module.app_and_jenkins.public_ip
}

output "frontend_url" {
  value = "http://${module.app_and_jenkins.public_ip}:${var.frontend_port}"
}

output "backend_url" {
  value = "http://${module.app_and_jenkins.public_ip}:${var.backend_port}/api/submit"
}

output "jenkins_url" {
  value = "http://${module.app_and_jenkins.public_ip}:${var.jenkins_port}"
}

output "ssh_command" {
  value = "ssh -i <path-to-${var.key_name}.pem> ubuntu@${module.app_and_jenkins.public_ip}"
}

output "vpc_id" {
  value = module.vpc.vpc_id
}
