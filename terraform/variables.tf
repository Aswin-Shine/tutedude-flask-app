variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-north-1"
}

variable "project_name" {
  description = "Prefix for resource names"
  type        = string
  default     = "tutedude-cicd"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "key_name" {
  description = "Name of an EXISTING EC2 key pair in this region, used for SSH access"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH in. Set to your own IP/32, not 0.0.0.0/0."
  type        = string
}

variable "github_repo_url" {
  description = "HTTPS URL of the app repo"
  type        = string
  default     = "https://github.com/Aswin-Shine/tutedude-flask-app.git"
}

variable "backend_port" {
  description = "Port the Flask backend listens on"
  type        = number
  default     = 5000
}

variable "frontend_port" {
  description = "Port the Express frontend listens on"
  type        = number
  default     = 3000
}

variable "jenkins_port" {
  description = "Port the Jenkins web UI listens on"
  type        = number
  default     = 8080
}

variable "mongo_secret_name" {
  description = "Name of the AWS Secrets Manager secret holding the Mongo URI."
  type        = string
  default     = "tutedude-cicd/mongo-uri"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC created by the official terraform-aws-modules/vpc/aws module"
  type        = string
  default     = "10.2.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the single public subnet the instance sits in"
  type        = string
  default     = "10.2.1.0/24"
}
