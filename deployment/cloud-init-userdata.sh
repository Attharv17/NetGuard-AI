#!/bin/bash
# =============================================================================
# NETGUARD AI — AWS EC2 Cloud-Init Bootstrap Script
# Paste this into the "User Data" field when launching a new EC2 instance.
# It runs once automatically on first boot as root.
# =============================================================================

#!/bin/bash
set -e

# Log everything to /var/log/netguard-init.log
exec > >(tee -a /var/log/netguard-init.log) 2>&1

echo "[$(date)] Starting NetGuard AI cloud-init bootstrap..."

# Wait for apt locks to clear (common on fresh Ubuntu AMIs)
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    echo "[$(date)] Waiting for apt lock..."
    sleep 5
done

# Install git only — the full setup is in setup-aws-ec2.sh
apt-get update -qq
apt-get install -y --no-install-recommends git

# Clone the public repository
git clone https://github.com/Attharv17/NetGuard-AI.git /home/ubuntu/netguard-ai
chown -R ubuntu:ubuntu /home/ubuntu/netguard-ai

# Run the full setup script
bash /home/ubuntu/netguard-ai/deployment/setup-aws-ec2.sh

echo "[$(date)] Bootstrap complete."
