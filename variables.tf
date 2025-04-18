variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "app_name" {
  description = "Name of the application"
  type        = string
  default     = "tradevis"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
}


variable "key_name" {
  description = "Name of the SSH key pair to use for EC2 instance"
  type        = string
  default     = null
}

variable "dockerhub_username" {
  description = "DockerHub username for pulling the frontend image"
  type        = string
  default     = "roeilevinson"  # Default value, can be overridden
}

variable "auth0_domain" {
  description = "Auth0 domain for authentication"
  type        = string
  sensitive   = true
  default     = ""  # Makes it optional during destroy
}

variable "auth0_audience" {
  description = "Auth0 API audience"
  type        = string
  sensitive   = true
  default     = ""  # Makes it optional during destroy
}

variable "auth0_client_secret" {
  description = "Auth0 client secret"
  type        = string
  sensitive   = true
  default     = ""  # Makes it optional during destroy
} 