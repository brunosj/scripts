#!/bin/bash

# Prompt for the username
read -p "Enter the new username: " USER

# Prompt for the domain
read -p "Enter your domain (e.g., example.com): " DOMAIN

# Create a new user and add them to the sudo group
sudo adduser $USER
sudo usermod -aG sudo $USER

# Install nvm, Node.js, npm, pnpm, pm2 globally (for the root user initially)
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Install Node.js version 20.18.0 using nvm
nvm install 20.18.0
nvm use 20.18.0

# Install pnpm globally
curl -fsSL https://get.pnpm.io/install.sh | sh -

# Install pm2 globally
npm install -g pm2

# Install Git
sudo apt update
sudo apt install -y git

# Configure Git globally
git config --global user.name "brunosj"
git config --global user.email "contact@landozone.net"

# Generate SSH key pair for the user
ssh-keygen -t rsa -b 4096 -C "contact@landozone.net" -f /home/$USER/.ssh/id_rsa -N ""

# Display the SSH public key
cd /home/$USER/.ssh
cat id_rsa.pub

# MongoDB Installation for Hetzner setup (MongoDB 8.0)
sudo apt install -y wget gnupg

# Add MongoDB 8.0 public key and repository
curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | \
   sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor

echo "deb [signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg] https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/8.0 multiverse" | \
   sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list

# Install MongoDB
sudo apt update
sudo apt install -y mongodb-org

# Start and enable MongoDB service
sudo systemctl start mongod
sudo systemctl enable mongod

# Prompt for MongoDB database name and password
read -p "Enter the MongoDB database name: " DB_NAME
read -s -p "Enter the MongoDB password for user $USER: " DB_PASSWORD
echo

# Create MongoDB database and user with specified password
sudo -u $USER mongo <<EOF
use $DB_NAME
db.createUser({
  user: "$USER",
  pwd: "$DB_PASSWORD",
  roles: [{ role: "readWrite", db: "$DB_NAME" }]
})
EOF

# Switch to the new user to run the rest of the operations
sudo -u $USER bash <<EOF

# Install Nginx for the user
sudo apt install -y nginx
sudo ufw allow 'OpenSSH'
sudo ufw allow 'http'
sudo ufw allow 'https'

# Enable the firewall
sudo ufw enable

# Check the firewall status
sudo ufw status

# Sync SSH config to the new user
rsync --archive --chown=${USER}:${USER} ~/.ssh /home/${USER}

# Nginx configuration with blue-green deployment
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
sudo tee $NGINX_CONF > /dev/null <<EON
upstream bluegreendeploy {
    server localhost:3000 weight=1;
    server localhost:3001 weight=1;
}

server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://bluegreendeploy;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }

    # Redirect www to non-www
    if (\$host = 'www.$DOMAIN') {
        return 301 http://$DOMAIN\$request_uri;
    }
}
EON

# Enable the configuration and restart Nginx
sudo ln -s $NGINX_CONF /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

# Install Certbot using snap and set up SSL certificate
sudo apt install snapd
sudo snap install --classic certbot
sudo ln -s /snap/bin/certbot /usr/bin/certbot
sudo certbot --nginx -d $DOMAIN -d www.$DOMAIN

EOF

# Echo completion message
echo "Setup completed"
echo "Showing content of public key"

# Show the public key
cat /home/$USER/.ssh/id_rsa.pub
