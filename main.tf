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
              
              # Create local kubeconfig directory
              mkdir -p /home/ec2-user/.kube
              chown ec2-user:ec2-user /home/ec2-user/.kube
              
              # Set DockerHub username
              DOCKERHUB_USERNAME="${var.dockerhub_username}"
              
              # Create Kind cluster configuration
              cat > /home/ec2-user/kind-config.yaml <<KINDCONFIG
              kind: Cluster
              apiVersion: kind.x-k8s.io/v1alpha4
              networking:
                apiServerAddress: "0.0.0.0"
                apiServerPort: 6443
              nodes:
              - role: control-plane
                kubeadmConfigPatches:
                - |
                  kind: InitConfiguration
                  nodeRegistration:
                    kubeletExtraArgs:
                      node-labels: "ingress-ready=true"
                      system-reserved: "memory=512Mi"
                    taints: []
                extraPortMappings:
                - containerPort: 80
                  hostPort: 80
                  protocol: TCP
                - containerPort: 443
                  hostPort: 443
                  protocol: TCP
              KINDCONFIG
              
              # Create a wrapper script to ensure proper environment
              cat > /home/ec2-user/create-cluster.sh <<'CREATESCRIPT'
              #!/bin/bash
              
              # Create the Kind cluster with increased timeout
              kind create cluster --config=/home/ec2-user/kind-config.yaml --wait 5m
              
              # Ensure kubeconfig is properly set
              mkdir -p $HOME/.kube
              kind get kubeconfig > $HOME/.kube/config
              chmod 600 $HOME/.kube/config
              
              # Set KUBECONFIG environment variable
              export KUBECONFIG=$HOME/.kube/config
              
              # Test connection
              kubectl cluster-info
              
              # Verify API server is accessible
              echo "Verifying API server connection..."
              if ! kubectl get nodes > /dev/null 2>&1; then
                echo "API server not accessible, restarting Docker..."
                sudo systemctl restart docker
                sleep 30
                
                echo "Recreating Kind cluster..."
                kind delete cluster || true
                kind create cluster --config=/home/ec2-user/kind-config.yaml --wait 5m
                kind get kubeconfig > $HOME/.kube/config
                chmod 600 $HOME/.kube/config
              fi
              CREATESCRIPT
              
              chmod +x /home/ec2-user/create-cluster.sh
              chown ec2-user:ec2-user /home/ec2-user/create-cluster.sh
              
              # Run the cluster creation script
              su - ec2-user -c "/home/ec2-user/create-cluster.sh"
              
              # Wait for the cluster to be fully ready
              su - ec2-user -c "KUBECONFIG=/home/ec2-user/.kube/config kubectl wait --for=condition=Ready nodes --all --timeout=5m || echo 'Not all nodes are ready but continuing'"
              
              # Install NGINX Ingress Controller
              su - ec2-user -c "KUBECONFIG=/home/ec2-user/.kube/config kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml"
              
              # Wait for ingress controller to be ready
              su - ec2-user -c "KUBECONFIG=/home/ec2-user/.kube/config kubectl wait --namespace ingress-nginx \
                --for=condition=ready pod \
                --selector=app.kubernetes.io/component=controller \
                --timeout=90s || echo 'Ingress controller not ready but continuing'"
              
              # Create Kubernetes deployment manifest
              cat > /home/ec2-user/deployment.yaml <<DEPLOYMENT
              apiVersion: apps/v1
              kind: Deployment
              metadata:
                name: tradevis-frontend
              spec:
                replicas: 1
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
                      resources:
                        requests:
                          memory: "128Mi"
                          cpu: "100m"
                        limits:
                          memory: "256Mi"
                          cpu: "500m"
                      ports:
                      - containerPort: 80
                      readinessProbe:
                        httpGet:
                          path: /
                          port: 80
                        initialDelaySeconds: 10
                        periodSeconds: 5
                      livenessProbe:
                        httpGet:
                          path: /
                          port: 80
                        initialDelaySeconds: 15
                        periodSeconds: 10
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
              su - ec2-user -c "KUBECONFIG=/home/ec2-user/.kube/config kubectl apply -f /home/ec2-user/deployment.yaml"
              
              # Wait for the deployment to be ready
              su - ec2-user -c "KUBECONFIG=/home/ec2-user/.kube/config kubectl wait --for=condition=available --timeout=300s deployment/tradevis-frontend || echo 'Deployment not ready but continuing'"
              
              # Pull the image into the Kind cluster
              su - ec2-user -c "docker pull $DOCKERHUB_USERNAME/tradevis-frontend:latest"
              su - ec2-user -c "kind load docker-image $DOCKERHUB_USERNAME/tradevis-frontend:latest"
              
              # Create a setup script for the user to run if needed
              cat > /home/ec2-user/setup-kind.sh <<'SETUPSCRIPT'
              #!/bin/bash
              
              export KUBECONFIG=$HOME/.kube/config
              
              echo "Checking cluster status..."
              kubectl cluster-info
              kubectl get nodes
              
              echo "Restarting deployment if needed..."
              kubectl rollout restart deployment/tradevis-frontend
              
              echo "Waiting for pods to be ready..."
              kubectl wait --for=condition=Ready pods --all --timeout=3m || echo "Not all pods are ready"
              
              echo "Current pod status:"
              kubectl get pods -A
              
              echo "You can access the application at http://localhost"
              SETUPSCRIPT
              
              chmod +x /home/ec2-user/setup-kind.sh
              
              # Create a troubleshooting script
              cat > /home/ec2-user/troubleshoot.sh <<'TROUBLESHOOT'
              #!/bin/bash
              
              export KUBECONFIG=$HOME/.kube/config
              
              echo "============ System Resources ============"
              free -h
              df -h
              
              echo "============ Docker Status ============"
              sudo systemctl status docker
              docker info
              
              echo "============ Kind Cluster Status ============"
              kind get clusters
              
              echo "============ Kubernetes Connectivity ============"
              kubectl cluster-info
              
              echo "============ Kubernetes Node Status ============"
              kubectl get nodes -o wide
              
              echo "============ Kubernetes Pod Status ============"
              kubectl get pods -A
              
              echo "============ Checking API Server ============"
              if ! curl -k https://localhost:6443/healthz; then
                echo "API server is not responding, attempting to fix..."
                
                echo "Restarting Docker..."
                sudo systemctl restart docker
                sleep 30
                
                echo "Rebuilding Kind cluster..."
                kind delete cluster || true
                kind create cluster --config=/home/ec2-user/kind-config.yaml
                
                echo "Retrieving new kubeconfig..."
                kind get kubeconfig > $HOME/.kube/config
                chmod 600 $HOME/.kube/config
                
                echo "Reapplying deployments..."
                kubectl apply -f /home/ec2-user/deployment.yaml
                
                echo "New cluster status:"
                kubectl get pods -A
              else
                echo "API server is healthy"
              fi
              TROUBLESHOOT
              
              chmod +x /home/ec2-user/troubleshoot.sh
              chown ec2-user:ec2-user /home/ec2-user/troubleshoot.sh
              
              # Set proper ownership for all files
              chown ec2-user:ec2-user /home/ec2-user/kind-config.yaml
              chown ec2-user:ec2-user /home/ec2-user/deployment.yaml
              chown ec2-user:ec2-user /home/ec2-user/setup-kind.sh
              chown ec2-user:ec2-user /home/ec2-user/troubleshoot.sh
              
              # Add kubectl to ec2-user's PATH and set KUBECONFIG
              echo 'export PATH=$PATH:/usr/local/bin' >> /home/ec2-user/.bashrc
              echo 'export KUBECONFIG=$HOME/.kube/config' >> /home/ec2-user/.bashrc
              EOF
} 