provider "aws" {
  region = var.aws_region
}

terraform {
  backend "s3" {
    bucket         = "tradevis-terraform-state"
    key            = "terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

# Get latest Amazon Linux 2 AMI
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Create VPC
resource "aws_vpc" "app_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  tags = {
    Name = "${var.app_name}-vpc"
  }
}

# Create Internet Gateway
resource "aws_internet_gateway" "app_igw" {
  vpc_id = aws_vpc.app_vpc.id
  tags = {
    Name = "${var.app_name}-igw"
  }
}

# Create Public Subnet
resource "aws_subnet" "app_public_subnet" {
  vpc_id                  = aws_vpc.app_vpc.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"
  tags = {
    Name = "${var.app_name}-public-subnet"
  }
}

# Create Route Table
resource "aws_route_table" "app_public_rt" {
  vpc_id = aws_vpc.app_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.app_igw.id
  }

  tags = {
    Name = "${var.app_name}-public-rt"
  }
}

# Associate Route Table with Subnet
resource "aws_route_table_association" "app_public_rt_assoc" {
  subnet_id      = aws_subnet.app_public_subnet.id
  route_table_id = aws_route_table.app_public_rt.id
}

# Create Security Group
resource "aws_security_group" "app_sg" {
  name        = "${var.app_name}-sg"
  description = "Allow HTTP, HTTPS and SSH traffic"
  vpc_id      = aws_vpc.app_vpc.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Kubernetes API Server"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Kubernetes NodePort Services"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.app_name}-sg"
  }
}

# Create EC2 Instance
resource "aws_instance" "app_server" {
  ami                    = data.aws_ami.amazon_linux_2.id
  instance_type          = var.instance_type
  key_name               = var.key_name != null ? var.key_name : null
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  subnet_id              = aws_subnet.app_public_subnet.id

  root_block_device {
    volume_size = 30
    volume_type = "gp2"
  }

  tags = {
    Name = "${var.app_name}-server"
  }

  user_data = <<-EOF
              #!/bin/bash
              # Update system packages
              yum update -y
              
              # Install Docker
              amazon-linux-extras install docker -y
              service docker start
              usermod -a -G docker ec2-user
              chkconfig docker on
              
              # Install Docker Compose
              curl -L "https://github.com/docker/compose/releases/download/v2.18.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
              chmod +x /usr/local/bin/docker-compose
              ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
              
              # Install kubectl
              curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
              chmod +x kubectl
              mv kubectl /usr/local/bin/
              
              # Install Kind
              curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
              chmod +x ./kind
              mv ./kind /usr/local/bin/kind
              
              # Set DockerHub username
              DOCKERHUB_USERNAME="${var.dockerhub_username}"
              
              # Create Kind cluster configuration
              cat > /home/ec2-user/kind-config.yaml <<KINDCONFIG
              kind: Cluster
              apiVersion: kind.x-k8s.io/v1alpha4
              nodes:
              - role: control-plane
                extraPortMappings:
                - containerPort: 80
                  hostPort: 80
                  protocol: TCP
              - role: worker
              - role: worker
              KINDCONFIG
              
              # Create the Kind cluster
              su - ec2-user -c "kind create cluster --config=/home/ec2-user/kind-config.yaml"
              
              # Create Kubernetes deployment manifest
              cat > /home/ec2-user/deployment.yaml <<DEPLOYMENT
              apiVersion: apps/v1
              kind: Deployment
              metadata:
                name: tradevis-frontend
              spec:
                replicas: 2
                selector:
                  matchLabels:
                    app: tradevis-frontend
                template:
                  metadata:
                    labels:
                      app: tradevis-frontend
                  spec:
                    containers:
                    - name: tradevis-frontend
                      image: $DOCKERHUB_USERNAME/tradevis-frontend:latest
                      ports:
                      - containerPort: 80
              ---
              apiVersion: v1
              kind: Service
              metadata:
                name: tradevis-frontend
              spec:
                type: NodePort
                ports:
                - port: 80
                  targetPort: 80
                selector:
                  app: tradevis-frontend
              ---
              apiVersion: networking.k8s.io/v1
              kind: Ingress
              metadata:
                name: tradevis-frontend-ingress
                annotations:
                  nginx.ingress.kubernetes.io/rewrite-target: /
              spec:
                rules:
                - http:
                    paths:
                    - path: /
                      pathType: Prefix
                      backend:
                        service:
                          name: tradevis-frontend
                          port:
                            number: 80
              DEPLOYMENT
              
              # Apply the Kubernetes manifests
              su - ec2-user -c "kubectl apply -f /home/ec2-user/deployment.yaml"
              
              # Pull the image into the Kind cluster
              su - ec2-user -c "docker pull $DOCKERHUB_USERNAME/tradevis-frontend:latest"
              su - ec2-user -c "kind load docker-image $DOCKERHUB_USERNAME/tradevis-frontend:latest"
              
              # Set proper ownership for all files
              chown ec2-user:ec2-user /home/ec2-user/kind-config.yaml
              chown ec2-user:ec2-user /home/ec2-user/deployment.yaml
              
              # Add kubectl to ec2-user's PATH
              echo 'export PATH=$PATH:/usr/local/bin' >> /home/ec2-user/.bashrc
              EOF
} 