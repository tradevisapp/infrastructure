output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.app_vpc.id
}

output "public_subnet_id" {
  description = "ID of the public subnet"
  value       = aws_subnet.app_public_subnet.id
}

output "security_group_id" {
  description = "ID of the security group"
  value       = aws_security_group.app_sg.id
}

output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.app_server.id
}

output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.app_server.public_ip
}

output "ssh_command" {
  description = "SSH command to connect to the EC2 instance"
  value       = var.key_name != null ? "ssh -i ${var.key_name}.pem ec2-user@${aws_instance.app_server.public_ip}" : "No SSH key provided. Instance can only be accessed through the AWS console or by creating a new key pair."
}

output "webhook_url" {
  description = "URL for the DockerHub webhook"
  value       = "http://${aws_instance.app_server.public_ip}:9000/webhook"
} 