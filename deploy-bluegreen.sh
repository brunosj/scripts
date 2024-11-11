#!/bin/bash
set -e

# Log the start of the script execution
echo "Deploy script started at $(date)" >> /tmp/deploy_script.log

# Prompt for the base directory path
read -p "Enter the base directory path (e.g., /home/lando): " LIVE_DIR_PATH
if [ -z "$LIVE_DIR_PATH" ]; then
  LIVE_DIR_PATH="/home/lando"
  echo "Using default base directory path: $LIVE_DIR_PATH"
fi
echo "Base directory set to: $LIVE_DIR_PATH"

# Prompt for the domain
read -p "Enter the domain (e.g., https://shush.dance): " DOMAIN
if [ -z "$DOMAIN" ]; then
  DOMAIN="https://shush.dance"
  echo "Using default domain: $DOMAIN"
fi
echo "Domain set to: $DOMAIN"

# Directories for the blue and green apps
BLUE_DIR="$LIVE_DIR_PATH/app-blue"
GREEN_DIR="$LIVE_DIR_PATH/app-green"
echo "Blue app directory: $BLUE_DIR"
echo "Green app directory: $GREEN_DIR"

# Function to check app status
check_app_status() {
    local domain=$1
    echo "Checking app status for $domain"
    if curl -s --head --fail "$domain" > /dev/null; then
        echo "$domain is responding"
        return 0
    else
        echo "$domain is not responding"
        return 1
    fi
}

# Function to check if a PM2 process exists
check_pm2_process() {
    local process_name=$1
    echo "Checking PM2 process: $process_name"
    if pm2 jlist | jq -e ".[] | select(.name == \"$process_name\" and .pm2_env.status == \"online\")" > /dev/null; then
        echo "$process_name is running"
        return 0
    else
        echo "$process_name is not running"
        return 1
    fi
}

# Check app status
echo "Checking domain status"
if ! check_app_status $DOMAIN; then
    echo "Domain is not responding, restarting both apps"

    # Check the status of blue app
    echo "Checking blue app status"
    if check_pm2_process blue; then
        echo "Blue app is running. Stopping blue"
        pm2 stop blue || echo 'Failed to stop blue process'
        pm2 delete blue || echo 'Failed to delete blue process'
    else
        echo 'Blue process does not exist, skipping deletion'
    fi

    # Check the status of green app
    echo "Checking green app status"
    if check_pm2_process green; then
        echo "Green app is running. Stopping green"
        pm2 stop green || echo 'Failed to stop green process'
        pm2 delete green || echo 'Failed to delete green process'
    else
        echo 'Green process does not exist, skipping deletion'
    fi

    # Start blue app
    echo "Starting blue app"
    cd $BLUE_DIR || { echo 'Could not access blue app directory' ; exit 1; }
    pm2 start "pnpm serve" --name "blue" || { echo 'Failed to start blue app' ; exit 1; }

    # Start green app
    echo "Starting green app"
    cd $GREEN_DIR || { echo 'Could not access green app directory' ; exit 1; }
    pm2 start "pnpm serve-green" --name "green" || { echo 'Failed to start green app' ; exit 1; }
else
    echo "Domain is responding, no need to restart apps"
fi

# Check if the green and blue apps are running
echo "Checking if green and blue apps are running"
GREEN_RUNNING="green is not running"
BLUE_RUNNING="blue is not running"
if check_pm2_process blue; then
    BLUE_RUNNING="blue is running"
fi
if check_pm2_process green; then
    GREEN_RUNNING="green is running"
fi

echo "BLUE_RUNNING: $BLUE_RUNNING"
echo "GREEN_RUNNING: $GREEN_RUNNING"

# Determine which app is running
CURRENT_LIVE_NAME=false
CURRENT_LIVE_DIR=false
DEPLOYING_TO_NAME=false
DEPLOYING_TO_DIR=false

if [ "$GREEN_RUNNING" == "green is running" ]; then
    echo "Green is running"
    CURRENT_LIVE_NAME="green"
    CURRENT_LIVE_DIR=$GREEN_DIR
    DEPLOYING_TO_NAME="blue"
    DEPLOYING_TO_DIR=$BLUE_DIR
fi

if [ "$BLUE_RUNNING" == "blue is running" ]; then
    echo "Blue is running"
    CURRENT_LIVE_NAME="blue"
    CURRENT_LIVE_DIR=$BLUE_DIR
    DEPLOYING_TO_NAME="green"
    DEPLOYING_TO_DIR=$GREEN_DIR
fi

if [ "$GREEN_RUNNING" == "green is running" ] && [ "$BLUE_RUNNING" == "blue is running" ]; then
    echo "Both blue and green are running"
    # If both apps are running, stop green and deploy to green
    echo "Stopping the green app as both are running"
    pm2 stop green || { echo "Failed to stop green" ; exit 1; }
    CURRENT_LIVE_NAME="blue"
    CURRENT_LIVE_DIR=$BLUE_DIR
    DEPLOYING_TO_NAME="green"
    DEPLOYING_TO_DIR=$GREEN_DIR
fi

echo "Current live: $CURRENT_LIVE_NAME"
echo "Deploying to: $DEPLOYING_TO_NAME"
echo "Current live dir: $CURRENT_LIVE_DIR"
echo "Deploying to dir: $DEPLOYING_TO_DIR"

# Navigate to the deploying to directory
echo "Navigating to the $DEPLOYING_TO_NAME directory"
cd $DEPLOYING_TO_DIR || { echo 'Could not access deployment directory' ; exit 1; }

# Use the correct node version
echo "Using node version 20.12.2"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm use 20.12.2 || { echo 'Could not switch to node version 20.12.2' ; exit 1; }

# Load the .env file
echo "Loading .env file"
source .env || { echo 'The ENV file does not exist' ; exit 1; }

# Pull the latest changes
echo "Pulling latest changes from Git"
git reset --hard || { echo 'Git reset command failed' ; exit 1; }
git pull -f origin main || { echo 'Git pull command failed' ; exit 1; }

# Clear the cache
echo "Clearing the .next, build, and dist caches"
rm -rf .next || { echo 'Clearing .next cache failed' ; exit 1; }
echo "Next cache cleared"
rm -rf build || { echo 'Clearing build cache failed' ; exit 1; }
echo "Build cache cleared"
rm -rf dist || { echo 'Clearing dist cache failed' ; exit 1; }
echo "Dist cache cleared"

# Install dependencies
echo "Installing dependencies"
pnpm install || { echo 'pnpm install failed' ; exit 1; }

# Determine the correct build command based on DEPLOYING_TO_NAME
echo "Building the project"
BUILD_COMMAND="pnpm build"
$BUILD_COMMAND || { echo 'Build failed' ; exit 1; }

# Restart the pm2 process
echo "Restarting the pm2 process for $DEPLOYING_TO_NAME"
pm2 restart $DEPLOYING_TO_NAME || { echo 'pm2 restart failed' ; exit 1; }

# Add a delay to allow the server to start
echo "Waiting for 5 seconds to allow the server to start"
sleep 5

# Check if the server is running
DEPLOYMENT_ONLINE=$(pm2 jlist | jq -r ".[] | select(.name == \"$DEPLOYING_TO_NAME\") | .name, .pm2_env.status" | tr -d '\n\r')

if [ "$DEPLOYMENT_ONLINE" == "${DEPLOYING_TO_NAME}online" ]; then
    echo "Deployment successful"
else
    echo "Deployment failed"
    exit 1
fi

# Stop the live one which is out of date
echo "Stopping the $CURRENT_LIVE_NAME app"
pm2 stop $CURRENT_LIVE_NAME || { echo "Failed to stop $CURRENT_LIVE_NAME" ; exit 1; }

# Final check to ensure the domain is up after deployment
echo "Waiting for 5 seconds before final check"
sleep 5

echo "Final check: Checking if domain is up"
if ! check_app_status $DOMAIN; then
    echo "Final check: Domain is not responding. Deployment may have failed"
    echo "Switching back to previous live app: $CURRENT_LIVE_NAME"
    pm2 start $CURRENT_LIVE_NAME || { echo "Failed to start $CURRENT_LIVE_NAME" ; exit 1; }
    exit 1
else
    echo "Final check: Domain is responding. Deployment successful"
fi
