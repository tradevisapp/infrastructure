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
                kubeadmConfigPatches:
                - |
                  kind: InitConfiguration
                  nodeRegistration:
                    taints: []
              - role: worker
                kubeadmConfigPatches:
                - |
                  kind: JoinConfiguration
                  nodeRegistration:
                    kubeletExtraArgs:
                      node-labels: "node-role.kubernetes.io/worker=worker"
              - role: worker
                kubeadmConfigPatches:
                - |
                  kind: JoinConfiguration
                  nodeRegistration:
                    kubeletExtraArgs:
                      node-labels: "node-role.kubernetes.io/worker=worker"
              KINDCONFIG
              
              # Create the Kind cluster
              su - ec2-user -c "kind create cluster --config=/home/ec2-user/kind-config.yaml"
              
              # Wait for cluster to be ready before proceeding
              su - ec2-user -c "kubectl wait --for=condition=ready node --all --timeout=300s"
              
              # Configure kubectl for ec2-user
              mkdir -p /home/ec2-user/.kube
              su - ec2-user -c "kind get kubeconfig > /home/ec2-user/.kube/config"
              chown -R ec2-user:ec2-user /home/ec2-user/.kube
              
              # Create a kubectl alias for root user
              mkdir -p /root/.kube
              kind get kubeconfig > /root/.kube/config
              echo 'export KUBECONFIG=/root/.kube/config' >> /root/.bashrc
              
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
                    affinity:
                      nodeAffinity:
                        requiredDuringSchedulingIgnoredDuringExecution:
                          nodeSelectorTerms:
                          - matchExpressions:
                            - key: kubernetes.io/hostname
                              operator: NotIn
                              values:
                              - kind-control-plane
                    tolerations:
                    - key: "node-role.kubernetes.io/control-plane"
                      operator: "Exists"
                      effect: "NoSchedule"
                    - key: "node.kubernetes.io/not-ready"
                      operator: "Exists"
                      effect: "NoSchedule"
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
              
              # Install Ingress controller
              su - ec2-user -c "kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml"
              
              # Wait for Ingress controller to be ready
              su - ec2-user -c "kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s"
              
              # Pull the image into the Kind cluster
              su - ec2-user -c "docker pull $DOCKERHUB_USERNAME/tradevis-frontend:latest"
              su - ec2-user -c "kind load docker-image $DOCKERHUB_USERNAME/tradevis-frontend:latest"
              
              # Set proper ownership for all files
              chown ec2-user:ec2-user /home/ec2-user/kind-config.yaml
              chown ec2-user:ec2-user /home/ec2-user/deployment.yaml
              
              # Add kubectl to ec2-user's PATH and set KUBECONFIG
              echo 'export PATH=$PATH:/usr/local/bin' >> /home/ec2-user/.bashrc
              echo 'export KUBECONFIG=/home/ec2-user/.kube/config' >> /home/ec2-user/.bashrc
              
              # Create a direct kubectl connection script
              cat > /home/ec2-user/connect-kubectl.sh <<CONNECT
              #!/bin/bash
              
              # Get the container ID of the control plane node
              CONTROL_PLANE_ID=$(docker ps | grep control-plane | awk '{print $1}')
              
              if [ -z "$CONTROL_PLANE_ID" ]; then
                echo "Error: Could not find the control-plane container"
                exit 1
              fi
              
              # Get the IP address of the control plane container
              CONTROL_PLANE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $CONTROL_PLANE_ID)
              
              if [ -z "$CONTROL_PLANE_IP" ]; then
                echo "Error: Could not get the IP address of the control-plane container"
                exit 1
              fi
              
              echo "Control plane container IP: $CONTROL_PLANE_IP"
              
              # Create a new kubeconfig file that uses the container's IP directly
              mkdir -p $HOME/.kube
              kind get kubeconfig > $HOME/.kube/config.original
              
              # Replace localhost with the container IP in the kubeconfig
              sed "s/127.0.0.1/$CONTROL_PLANE_IP/g" $HOME/.kube/config.original > $HOME/.kube/config
              
              # Set permissions
              chmod 600 $HOME/.kube/config
              
              # Export KUBECONFIG
              export KUBECONFIG=$HOME/.kube/config
              
              # Test the connection
              echo "Testing connection to Kubernetes API server..."
              kubectl cluster-info
              
              if [ $? -eq 0 ]; then
                echo "Connection successful!"
                echo "Adding KUBECONFIG to .bashrc..."
                echo "export KUBECONFIG=$HOME/.kube/config" > $HOME/.bashrc_kubectl
                grep -q "source ~/.bashrc_kubectl" $HOME/.bashrc || echo "source ~/.bashrc_kubectl" >> $HOME/.bashrc
              else
                echo "Connection failed. Please check the cluster status."
              fi
              CONNECT
              
              chmod +x /home/ec2-user/connect-kubectl.sh
              chown ec2-user:ec2-user /home/ec2-user/connect-kubectl.sh
              
              # Create a welcome script
              cat > /home/ec2-user/welcome.sh <<WELCOME
              #!/bin/bash
              
              echo "===== Welcome to TradeVis Kubernetes Cluster ====="
              echo ""
              echo "Your Kind Kubernetes cluster should be running."
              echo ""
              echo "If you're experiencing connection issues with the Kubernetes API server,"
              echo "run the connection fix script first:"
              echo ""
              echo "   ./connect-kubectl.sh"
              echo ""
              echo "Other helpful commands:"
              echo ""
              echo "1. Verify the cluster is running:"
              echo "   kind get clusters"
              echo ""
              echo "2. Check if the API server is accessible:"
              echo "   kubectl cluster-info"
              echo ""
              echo "3. If you're still having issues, run the troubleshooting script:"
              echo "   ./troubleshoot.sh"
              echo ""
              echo "4. To fix common node issues:"
              echo "   ./fix-nodes.sh"
              echo ""
              echo "5. To completely restart the cluster:"
              echo "   ./restart-cluster.sh"
              echo ""
              echo "6. To check the status of your application:"
              echo "   kubectl get pods"
              echo "   kubectl get services"
              echo ""
              echo "Your application should be accessible at: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)"
              echo ""
              WELCOME
              
              chmod +x /home/ec2-user/welcome.sh
              chown ec2-user:ec2-user /home/ec2-user/welcome.sh
              
              # Add welcome script to .bashrc
              echo './welcome.sh' >> /home/ec2-user/.bashrc
              
              # Create a troubleshooting script
              cat > /home/ec2-user/troubleshoot.sh <<TROUBLESHOOT
              #!/bin/bash
              
              echo "===== CLUSTER DIAGNOSTICS ====="
              
              echo "1. Node Status:"
              kubectl get nodes -o wide
              
              echo "2. Pod Status:"
              kubectl get pods -A -o wide
              
              echo "3. Describe Nodes:"
              kubectl describe nodes
              
              echo "4. Describe Pods:"
              kubectl describe pods
              
              echo "5. Checking for taints:"
              kubectl get nodes -o=custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
              
              echo "6. Checking system pods:"
              kubectl get pods -n kube-system
              
              echo "7. Checking logs for unschedulable pods:"
              kubectl get events | grep -i "pod" | grep -i "fail"
              
              echo "8. Checking Docker status:"
              systemctl status docker
              
              echo "9. Checking Kind containers:"
              docker ps
              
              echo "10. Checking available resources:"
              kubectl describe nodes | grep -A 5 "Allocated resources"
              
              echo "===== ATTEMPTING FIXES ====="
              
              echo "1. Removing all taints from nodes:"
              kubectl taint nodes --all node-role.kubernetes.io/control-plane- node-role.kubernetes.io/master- node.kubernetes.io/not-ready- --overwrite
              
              echo "2. Ensuring worker nodes are labeled correctly:"
              kubectl label node kind-worker node-role.kubernetes.io/worker=worker --overwrite
              kubectl label node kind-worker2 node-role.kubernetes.io/worker=worker --overwrite
              
              echo "3. Restarting deployment:"
              kubectl rollout restart deployment tradevis-frontend
              
              echo "4. Waiting for deployment to be ready:"
              kubectl rollout status deployment/tradevis-frontend --timeout=300s
              
              echo "5. Final pod status:"
              kubectl get pods -o wide
              TROUBLESHOOT
              
              chmod +x /home/ec2-user/troubleshoot.sh
              chown ec2-user:ec2-user /home/ec2-user/troubleshoot.sh
              
              # Create a script to check and fix node issues
              cat > /home/ec2-user/fix-nodes.sh <<FIXSCRIPT
              #!/bin/bash
              
              echo "===== FIXING KUBERNETES CLUSTER ISSUES ====="
              
              # Fix kubectl configuration
              echo "Fixing kubectl configuration..."
              mkdir -p \$HOME/.kube
              kind get kubeconfig > \$HOME/.kube/config
              export KUBECONFIG=\$HOME/.kube/config
              
              # Check if API server is accessible
              echo "Checking API server connection..."
              if ! kubectl cluster-info; then
                echo "API server not accessible. Attempting to fix..."
                
                # Check if Kind cluster is running
                if ! kind get clusters | grep -q kind; then
                  echo "Kind cluster not found. Creating a new one..."
                  kind create cluster --config=/home/ec2-user/kind-config.yaml
                else
                  echo "Kind cluster exists. Trying to reconnect..."
                  kind export kubeconfig
                fi
              fi
              
              # Remove taints from all nodes
              echo "Removing taints from nodes..."
              kubectl taint nodes --all node-role.kubernetes.io/control-plane- node-role.kubernetes.io/master- node.kubernetes.io/not-ready- --overwrite
              
              # Label worker nodes
              echo "Labeling worker nodes..."
              kubectl label node kind-worker node-role.kubernetes.io/worker=worker --overwrite
              kubectl label node kind-worker2 node-role.kubernetes.io/worker=worker --overwrite
              
              # Wait for nodes to be ready
              echo "Waiting for nodes to be ready..."
              kubectl wait --for=condition=ready node --all --timeout=300s
              
              # Check node status
              echo "Node status:"
              kubectl get nodes
              
              # Check pod status
              echo "Pod status:"
              kubectl get pods -A
              
              # Force redeployment if needed
              echo "Restarting deployment..."
              kubectl rollout restart deployment tradevis-frontend
              
              # Wait for deployment to be ready
              echo "Waiting for deployment to be ready..."
              kubectl rollout status deployment/tradevis-frontend --timeout=300s
              
              # Show where pods are scheduled
              echo "Pod scheduling:"
              kubectl get pods -o wide
              
              echo "===== FIX COMPLETE ====="
              echo "If you're still experiencing issues, try running ./troubleshoot.sh"
              FIXSCRIPT
              
              chmod +x /home/ec2-user/fix-nodes.sh
              chown ec2-user:ec2-user /home/ec2-user/fix-nodes.sh
              
              # Run the fix script
              su - ec2-user -c "/home/ec2-user/fix-nodes.sh"
              
              # Create a restart cluster script
              cat > /home/ec2-user/restart-cluster.sh <<RESTART
              #!/bin/bash
              
              echo "===== RESTARTING KIND KUBERNETES CLUSTER ====="
              
              # Delete existing cluster if it exists
              if kind get clusters | grep -q kind; then
                echo "Deleting existing Kind cluster..."
                kind delete cluster
              fi
              
              # Create new cluster
              echo "Creating new Kind cluster..."
              kind create cluster --config=/home/ec2-user/kind-config.yaml
              
              # Run the connection script
              echo "Setting up kubectl connection..."
              ./connect-kubectl.sh
              
              # Wait for nodes to be ready
              echo "Waiting for nodes to be ready..."
              kubectl wait --for=condition=ready node --all --timeout=300s
              
              # Pull and load the image
              echo "Loading image into cluster..."
              docker pull roeilevinson/tradevis-frontend:latest
              kind load docker-image roeilevinson/tradevis-frontend:latest
              
              # Apply deployment
              echo "Applying deployment..."
              kubectl apply -f /home/ec2-user/deployment.yaml
              
              # Install Ingress controller
              echo "Installing Ingress controller..."
              kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
              
              # Wait for Ingress controller to be ready
              echo "Waiting for Ingress controller to be ready..."
              kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s || true
              
              # Run fix script
              echo "Running fix script..."
              ./fix-nodes.sh
              
              echo "===== CLUSTER RESTART COMPLETE ====="
              echo "Check cluster status with: kubectl get nodes"
              echo "Check pod status with: kubectl get pods -A"
              RESTART
              
              chmod +x /home/ec2-user/restart-cluster.sh
              chown ec2-user:ec2-user /home/ec2-user/restart-cluster.sh
              
              # Create a troubleshooting script
              cat > /home/ec2-user/troubleshoot.sh <<TROUBLESHOOT
              #!/bin/bash
              
              echo "===== CLUSTER DIAGNOSTICS ====="
              
              echo "1. Node Status:"
              kubectl get nodes -o wide
              
              echo "2. Pod Status:"
              kubectl get pods -A -o wide
              
              echo "3. Describe Nodes:"
              kubectl describe nodes
              
              echo "4. Describe Pods:"
              kubectl describe pods
              
              echo "5. Checking for taints:"
              kubectl get nodes -o=custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
              
              echo "6. Checking system pods:"
              kubectl get pods -n kube-system
              
              echo "7. Checking logs for unschedulable pods:"
              kubectl get events | grep -i "pod" | grep -i "fail"
              
              echo "8. Checking Docker status:"
              systemctl status docker
              
              echo "9. Checking Kind containers:"
              docker ps
              
              echo "10. Checking available resources:"
              kubectl describe nodes | grep -A 5 "Allocated resources"
              
              echo "===== ATTEMPTING FIXES ====="
              
              echo "1. Removing all taints from nodes:"
              kubectl taint nodes --all node-role.kubernetes.io/control-plane- node-role.kubernetes.io/master- node.kubernetes.io/not-ready- --overwrite
              
              echo "2. Ensuring worker nodes are labeled correctly:"
              kubectl label node kind-worker node-role.kubernetes.io/worker=worker --overwrite
              kubectl label node kind-worker2 node-role.kubernetes.io/worker=worker --overwrite
              
              echo "3. Restarting deployment:"
              kubectl rollout restart deployment tradevis-frontend
              
              echo "4. Waiting for deployment to be ready:"
              kubectl rollout status deployment/tradevis-frontend --timeout=300s
              
              echo "5. Final pod status:"
              kubectl get pods -o wide
              TROUBLESHOOT
              
              chmod +x /home/ec2-user/troubleshoot.sh
              chown ec2-user:ec2-user /home/ec2-user/troubleshoot.sh
              
              # Run the connection script for ec2-user
              su - ec2-user -c "/home/ec2-user/connect-kubectl.sh"
              EOF
} 