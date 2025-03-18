#!/bin/bash

# Update system packages
yum update -y

# Install git
yum install -y git

# Clone the repository
git clone https://github.com/tradevisapp/app

echo "Repository cloned successfully"

