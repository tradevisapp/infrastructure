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
    description = "Frontend App"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Webhook Server"
    from_port   = 9000
    to_port     = 9000
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
              
              # Install Node.js for webhook server
              curl -sL https://rpm.nodesource.com/setup_16.x | bash -
              yum install -y nodejs
              
              # Create webhook server file
              cat > /home/ec2-user/webhook-server.js <<'WEBHOOKSERVER'
              const http = require('http');
              const { exec } = require('child_process');
              
              const PORT = 9000;
              const SECRET = process.env.WEBHOOK_SECRET || 'your-webhook-secret';
              
              const server = http.createServer((req, res) => {
                if (req.method === 'POST' && req.url === '/webhook') {
                  let body = '';
                  
                  req.on('data', chunk => {
                    body += chunk.toString();
                  });
                  
                  req.on('end', () => {
                    try {
                      const payload = JSON.parse(body);
                      
                      // Verify it's from DockerHub
                      if (payload.push_data && payload.repository) {
                        console.log(`Received webhook for ${payload.repository.name}:${payload.push_data.tag}`);
                        
                        // Pull the latest image and restart the container
                        exec('cd /home/ec2-user && docker-compose pull frontend && docker-compose up -d', 
                          (error, stdout, stderr) => {
                            if (error) {
                              console.error(`Error: ${error.message}`);
                              return;
                            }
                            if (stderr) {
                              console.error(`stderr: ${stderr}`);
                            }
                            console.log(`stdout: ${stdout}`);
                            console.log('Container updated successfully');
                          }
                        );
                        
                        res.statusCode = 200;
                        res.end('Webhook received and processing');
                      } else {
                        res.statusCode = 400;
                        res.end('Invalid webhook payload');
                      }
                    } catch (error) {
                      console.error('Error processing webhook:', error);
                      res.statusCode = 400;
                      res.end('Error processing webhook');
                    }
                  });
                } else {
                  res.statusCode = 404;
                  res.end('Not found');
                }
              });
              
              server.listen(PORT, () => {
                console.log(`Webhook server running on port ${PORT}`);
              });
              WEBHOOKSERVER
              
              # Set proper ownership
              chown ec2-user:ec2-user /home/ec2-user/webhook-server.js
              
              # Create systemd service file for webhook server
              cat > /etc/systemd/system/webhook.service <<'WEBHOOKSERVICE'
              [Unit]
              Description=DockerHub Webhook Server
              After=network.target
              
              [Service]
              Environment=NODE_ENV=production
              Environment=WEBHOOK_SECRET=${var.webhook_secret}
              Type=simple
              User=ec2-user
              ExecStart=/usr/bin/node /home/ec2-user/webhook-server.js
              Restart=on-failure
              
              [Install]
              WantedBy=multi-user.target
              WEBHOOKSERVICE
              
              # Enable and start webhook service
              systemctl enable webhook.service
              systemctl start webhook.service
              
              # Create docker-compose.yml file
              cat > /home/ec2-user/docker-compose.yml <<'DOCKERCOMPOSE'
              version: '3.8'
              
              services:
                hello-world:
                  image: nginxdemos/hello:latest
                  container_name: hello-world
                  restart: unless-stopped
                  ports:
                    - "80:80"
                  networks:
                    - app-network
                
                frontend:
                  image: ${DOCKERHUB_USERNAME}/tradevis-frontend:latest
                  container_name: tradevis-frontend
                  restart: unless-stopped
                  ports:
                    - "3000:80"
                  networks:
                    - app-network
              
              networks:
                app-network:
                  driver: bridge
              DOCKERCOMPOSE
              
              # Set proper ownership
              chown ec2-user:ec2-user /home/ec2-user/docker-compose.yml
              
              # Set environment variables for docker-compose
              echo "DOCKERHUB_USERNAME=${var.dockerhub_username}" > /home/ec2-user/.env
              chown ec2-user:ec2-user /home/ec2-user/.env
              
              # Start the container
              cd /home/ec2-user
              docker-compose up -d
              EOF
} 