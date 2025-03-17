# TradeVis Infrastructure

This repository contains the infrastructure code for the TradeVis application, which runs a containerized frontend and backend on AWS.

## Repository Structure

- Terraform files (main.tf, variables.tf, outputs.tf) - AWS infrastructure configuration
- docker-compose.yml - Sample Docker Compose configuration for the application
- .github/workflows/ - Contains CI/CD pipelines
  - terraform.yml - GitHub Actions workflow for Terraform deployment

## Infrastructure Components

- VPC with public subnet
- Internet Gateway
- Security Group (allowing SSH, HTTP, HTTPS)
- EC2 instance with Docker and Docker Compose pre-installed
- Automatically deploys a hello world web server (NGINX-based)

## CI/CD Pipeline

The repository includes a GitHub Actions workflow that automatically:

1. Validates Terraform code
2. Plans infrastructure changes
3. Applies changes when code is pushed to the main branch

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) (v1.0.0+)
- AWS CLI configured with appropriate credentials
- SSH key pair for EC2 instance access

## Getting Started

1. Clone this repository
2. Update the `variables.tf` file with your preferred settings or create a `terraform.tfvars` file
3. Initialize Terraform:
   ```
   terraform init
   ```
4. Plan the deployment:
   ```
   terraform plan
   ```
5. Apply the configuration:
   ```
   terraform apply
   ```

## Accessing the Hello World Application

After the infrastructure is deployed, you can access the hello world application by navigating to the EC2 instance's public IP address in your web browser:

```
http://<instance-public-ip>
```

The public IP address will be displayed in the Terraform output.

## Connecting to the EC2 Instance

You can connect to the EC2 instance using SSH:

```
ssh -i your-key-pair.pem ec2-user@<instance-public-ip>
```

## Customizing the Application

The EC2 instance is configured to automatically deploy a hello world container using Docker Compose. You can modify the Docker Compose configuration by editing the file at `/home/ec2-user/docker-compose.yml` on the EC2 instance.

To apply changes to the Docker Compose configuration:

```
cd /home/ec2-user
docker-compose down
docker-compose up -d
```

## Required GitHub Secrets

To use the CI/CD pipeline, you need to set up the following GitHub secrets:

- `AWS_ACCESS_KEY_ID` - AWS access key with permissions to create resources
- `AWS_SECRET_ACCESS_KEY` - Corresponding AWS secret key
- `TF_API_TOKEN` - (Optional) Terraform Cloud API token if using Terraform Cloud

And the following GitHub variable:
- `AWS_REGION` - AWS region to deploy resources (e.g., us-east-1)

## Cleaning Up

To destroy the infrastructure when no longer needed:

```
terraform destroy
``` 