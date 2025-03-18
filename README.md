# TradeVis Infrastructure

This repository contains the infrastructure code for the TradeVis application, which runs a containerized frontend and backend on AWS.

## Repository Structure

- Terraform files (main.tf, variables.tf, outputs.tf) - AWS infrastructure configuration
- terraform-state.tf - Configuration for S3 backend and state locking
- docker-compose.yml - Sample Docker Compose configuration for the application
- .github/workflows/ - Contains CI/CD pipelines
  - terraform-apply.yml - GitHub Actions workflow for Terraform deployment
  - terraform-destroy.yml - GitHub Actions workflow for Terraform destruction
  - aws-nuke.yml - GitHub Actions workflow for complete AWS resource cleanup

## Infrastructure Components

- VPC with public subnet
- Internet Gateway
- Security Group (allowing SSH, HTTP, HTTPS, and Kubernetes ports)
- EC2 instance with Docker, Kind, and kubectl pre-installed
- Automatically deploys a Kubernetes cluster using Kind with the tradevis-frontend image
- S3 bucket for Terraform state storage
- DynamoDB table for state locking

## CI/CD Pipeline

The repository includes GitHub Actions workflows that:

1. **Terraform Apply**: Automatically validates, plans, and applies infrastructure changes when code is pushed to the main branch
2. **Terraform Destroy**: Can be manually triggered to destroy the infrastructure
3. **AWS Nuke**: Provides complete cleanup of all AWS resources

### Using the GitHub Actions Workflows

- **Apply**: The workflow automatically applies changes when you push to the main branch. You can also manually trigger it:
  1. Go to the "Actions" tab in your GitHub repository
  2. Select the "Terraform Apply" workflow
  3. Click "Run workflow"
  4. Click "Run workflow"

- **Destroy**: To destroy the infrastructure:
  1. Go to the "Actions" tab in your GitHub repository
  2. Select the "Terraform Destroy" workflow
  3. Click "Run workflow"
  4. Click "Run workflow"

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) (v1.0.0+)
- AWS CLI configured with appropriate credentials
- (Optional) SSH key pair for EC2 instance access

## Terraform State Management

This project uses an S3 backend for storing Terraform state, which provides:
- Secure storage of state files
- State locking via DynamoDB to prevent concurrent modifications
- State versioning for backup and recovery

The S3 bucket and DynamoDB table are automatically created by the GitHub Actions workflow if they don't exist.

## Getting Started

1. Clone this repository
2. Update the `variables.tf` file with your preferred settings or create a `terraform.tfvars` file
   - If you want SSH access to the instance, set the `key_name` variable to an existing key pair name in your AWS account
3. Initialize Terraform with the S3 backend:
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

## Accessing the Application

After the infrastructure is deployed, you can access the application by navigating to the EC2 instance's public IP address in your web browser:

```
http://<instance-public-ip>
```

The public IP address will be displayed in the Terraform output.

## Connecting to the EC2 Instance and Managing the Kubernetes Cluster

If you provided an SSH key pair name, you can connect to the EC2 instance using SSH:

```
ssh -i your-key-pair.pem ec2-user@<instance-public-ip>
```

Once connected, you can manage the Kubernetes cluster using kubectl:

```
# View all pods
kubectl get pods

# View all services
kubectl get services

# View all deployments
kubectl get deployments

# View the cluster info
kubectl cluster-info
```

### Troubleshooting Kubernetes Cluster

If you encounter any issues with the Kubernetes cluster, helper scripts are provided to assist with common tasks and troubleshooting:

```
# Run the basic setup script
./setup-kind.sh

# For more comprehensive troubleshooting
./troubleshoot.sh
```

The troubleshooting script will:
1. Check system resources
2. Verify Docker status
3. Check Kind cluster status
4. Test Kubernetes connectivity
5. Display node and pod status
6. Test API server health
7. Automatically rebuild the cluster if needed

Common issues that might occur:
- Node taints preventing pod scheduling
- Resource constraints
- Image pull failures
- API server connectivity issues

You can check for these issues with these commands:

```
# Check node status and taints
kubectl describe nodes

# Check pod status
kubectl get pods -A

# Check pod details
kubectl describe pod <pod-name>

# Check API server health
curl -k https://localhost:6443/healthz
```

If you didn't provide a key pair name, you won't be able to SSH into the instance directly. You can still access the web application through the browser.

## Customizing the Kubernetes Deployment

The EC2 instance is configured to automatically deploy the tradevis-frontend image in a Kind Kubernetes cluster. You can modify the Kubernetes deployment by editing the file at `/home/ec2-user/deployment.yaml` on the EC2 instance.

To apply changes to the Kubernetes deployment:

```
cd /home/ec2-user
kubectl apply -f deployment.yaml
```

## Required GitHub Secrets

To use the CI/CD pipeline, you need to set up the following GitHub secrets:

- `AWS_ACCESS_KEY_ID` - AWS access key with permissions to create resources
- `AWS_SECRET_ACCESS_KEY` - Corresponding AWS secret key
- `AWS_ACCOUNT_ID` - Your AWS account ID (required for AWS Nuke)
- `TF_API_TOKEN` - (Optional) Terraform Cloud API token if using Terraform Cloud

## Cleaning Up

### Using Terraform Destroy Workflow (Recommended for normal use)

To destroy the infrastructure using GitHub Actions:
1. Go to the "Actions" tab in your GitHub repository
2. Select the "Terraform Destroy" workflow
3. Click "Run workflow"
4. Click "Run workflow"

### Using AWS Nuke (For complete cleanup)

If you need to completely clean up all AWS resources, including those that might not be managed by Terraform:

1. Go to the "Actions" tab in your GitHub repository
2. Select the "AWS Nuke - Resource Cleanup" workflow
3. Click "Run workflow"
4. Type "yes-delete-all" in the confirmation field
5. Click "Run workflow"

**Warning**: AWS Nuke will delete **ALL** resources specified in the configuration. Use with extreme caution and only in development/testing environments.

### Using Terraform CLI

To destroy the infrastructure using the Terraform CLI:

```
terraform destroy
``` 