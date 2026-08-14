data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# VPC via terraform-aws-modules
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  azs            = [data.aws_availability_zones.available.names[0]]
  public_subnets = [var.public_subnet_cidr]

  enable_dns_support   = true
  enable_dns_hostnames = true
  private_subnets      = []

  tags = {
    Project = var.project_name
  }
}

resource "aws_security_group" "app_and_jenkins_sg" {
  name        = "${var.project_name}-sg"
  description = "SSH, Flask, Express, Jenkins UI"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "Express frontend"
    from_port   = var.frontend_port
    to_port     = var.frontend_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Flask backend"
    from_port   = var.backend_port
    to_port     = var.backend_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Jenkins UI + GitHub webhook endpoint"
    from_port   = var.jenkins_port
    to_port     = var.jenkins_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg"
  }
}

# AWS Secret Manager
resource "aws_secretsmanager_secret" "mongo_uri" {
  name        = var.mongo_secret_name
  description = "MongoDB Atlas connection string for the Flask backend. Value set out-of-band, not by Terraform."
}

resource "aws_iam_role" "app_instance_role" {
  name = "${var.project_name}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "read_mongo_secret" {
  name = "${var.project_name}-read-mongo-secret"
  role = aws_iam_role.app_instance_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.mongo_uri.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.app_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "app_instance_profile" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.app_instance_role.name
}

module "app_and_jenkins" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 5.6"

  name = "${var.project_name}-app-and-jenkins"

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = module.vpc.public_subnets[0]
  vpc_security_group_ids = [aws_security_group.app_and_jenkins_sg.id]

  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.app_instance_profile.name

  user_data = templatefile("${path.module}/templates/user_data.sh.tpl", {
    github_repo_url   = var.github_repo_url
    backend_port      = var.backend_port
    frontend_port     = var.frontend_port
    aws_region        = var.aws_region
    mongo_secret_name = var.mongo_secret_name
    project_name      = var.project_name
  })
  user_data_replace_on_change = true

  root_block_device = [
    {
      volume_size = 20
      volume_type = "gp3"
      encrypted   = true
    }
  ]

  tags = {
    Name = "${var.project_name}-app-and-jenkins"
  }
}
