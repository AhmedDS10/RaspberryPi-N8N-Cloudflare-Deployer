#!/bin/bash
# Automatic n8n installer for Raspberry Pi
# Author: Łukasz Podgórski & Anthropic Claude
# Date: 13.03.2025
# Version: 2.6 (simplified permissions)
# Guide from: www.przewodnikai.pl
# YouTube Channel: https://www.youtube.com/@lukaszpodgorski
#
# GitHub: https://github.com/xshocuspocusxd/RaspberryPi-N8N-Cloudflare-Deployer
#
# wget -O install-n8n.sh https://www.przewodnikai.pl/scripts/rpi-n8n-installer.sh && chmod +x install-n8n.sh

# Set colors for better terminal readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

db_user="user"  # Default value
db_password="n8n_password"  # Default value

# Function to display information
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Function to display success
success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Function to display warnings
warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to display errors
error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to verify if the user wants to continue
confirm() {
    read -p "Do you want to continue? (y/n): " response
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to check if we are on a Raspberry Pi
check_raspberry_pi() {
    if [ ! -f /proc/device-tree/model ] || ! grep -q "Raspberry Pi" /proc/device-tree/model; then
        error "This script is intended to be run on a Raspberry Pi."
        exit 1
    fi
}

# Function to check if we have sufficient privileges
check_privileges() {
    if ! groups | grep -q "sudo\|root"; then
        error "This script requires administrator (sudo) privileges."
        exit 1
    fi
}

# Function to update the system
update_system() {
    info "Updating system..."
    sudo apt update && sudo apt upgrade -y
    success "System updated."
}

# Function to install Docker
install_docker() {
    info "Installing Docker..."
    if ! command -v docker &> /dev/null; then
        curl -sSL https://get.docker.com | sh
        sudo usermod -aG docker $USER
        success "Docker installed. A system restart will be required."
        
        # Save information that Docker was freshly installed
        touch ~/.docker_fresh_install
        
        # Ask for system restart
        warning "The system must be restarted for changes to take effect."
        info "After restarting, run the script again to continue the installation."
        read -p "Do you want to restart the system now? (y/n): " restart_now
        if [[ "$restart_now" =~ ^[yY] ]]; then
            info "Restarting system..."
            sudo reboot
            exit 0
        else
            warning "Remember to restart the system before continuing."
            exit 0
        fi
    else
        success "Docker is already installed."
    fi
}

# Function to install Docker Compose
install_docker_compose() {
    info "Installing Docker Compose..."
    if ! command -v docker-compose &> /dev/null; then
        sudo apt install -y docker-compose
        success "Docker Compose installed."
    else
        success "Docker Compose is already installed."
    fi
}

# Function to configure n8n
configure_n8n() {
    info "Configuring n8n..."
    
    # Get user data ONLY ONCE
    read -p "Enter the domain for n8n (e.g., mydomain-n8n.com): " domain_name
    read -p "Enter the PostgreSQL database password [n8n_password]: " db_password
    db_password=${db_password:-n8n_password}
    
    # Create project directory
    mkdir -p ~/n8n
    
    # Create n8n data directory with appropriate permissions
    mkdir -p ~/.n8n
    sudo chown -R $USER:$USER ~/.n8n
    sudo chmod -R 755 ~/.n8n
    
    # Create docker-compose.yml file
    cat > ~/n8n/docker-compose.yml << EOF
version: '3'

services:
  postgres:
    image: postgres:15.8
    restart: always
    environment:
      - POSTGRES_USER=${db_user}
      - POSTGRES_PASSWORD=${db_password}
      - POSTGRES_DB=n8n

    volumes:
      - postgres_data:/var/lib/postgresql/data

  n8n:
    image: n8nio/n8n
    user: "root"
    restart: always
    ports:
      - '8443:5678'
    environment:
      - N8N_HOST=localhost
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - NODE_ENV=production
      - WEBHOOK_URL=https://${domain_name}
      # PostgreSQL connection configuration
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=${db_user}
      - DB_POSTGRESDB_PASSWORD=${db_password}
    volumes:
      - ~/.n8n:/home/node/.n8n
    depends_on:
      - postgres

volumes:
  postgres_data:
EOF
    
    success "n8n configuration created in ~/n8n/docker-compose.yml"
}

# Function to install Cloudflared
install_cloudflared() {
    info "Installing Cloudflared..."
    if ! command -v cloudflared &> /dev/null; then
        sudo mkdir -p /usr/local/bin
        cd /usr/local/bin
        sudo curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o cloudflared
        sudo chmod +x cloudflared
        success "Cloudflared installed. Version: $(cloudflared --version)"
    else
        success "Cloudflared is already installed. Version: $(cloudflared --version)"
    fi
}

# Helper function to find the credentials file
find_credential_file() {
    local tunnel_id=$1
    local credential_file=""
    
    # Possible locations for credentials files
    local cloudflared_dirs=("/root/.cloudflared" "$HOME/.cloudflared")
    
    # Search for JSON file with tunnel ID in found directories
    for dir in "${cloudflared_dirs[@]}"; do
        if [ -d "$dir" ]; then
            potential_file=$(find "$dir" -name "*.json" -type f | grep -i "${tunnel_id}" | head -n 1)
            if [ -n "$potential_file" ] && [ -f "$potential_file" ]; then
                credential_file="$potential_file"
                break
            fi
        fi
    done
    
    # If file not found, search directories again for all JSON files
    if [ -z "$credential_file" ]; then
        for dir in "${cloudflared_dirs[@]}"; do
            if [ -d "$dir" ]; then
                info "Checking JSON files in directory $dir:"
                ls -la "$dir"/*.json 2>/dev/null || echo "No JSON files in $dir"
                
                # Select first JSON file if any exists
                potential_file=$(find "$dir" -name "*.json" -type f | head -n 1)
                if [ -n "$potential_file" ] && [ -f "$potential_file" ]; then
                    credential_file="$potential_file"
                    warning "No tunnel-specific file found, using: $credential_file"
                    break
                fi
            fi
        done
    fi
    
    echo "$credential_file"
}

# Function to configure Cloudflare Tunnel
configure_cloudflare_tunnel() {
    info "Configuring Cloudflare Tunnel..."
    
    warning "You must have a domain added to Cloudflare. If you haven't done this yet, stop the installation and perform this step manually."
    if ! confirm; then
        exit 1
    fi
    
    # Prepare directories
    sudo mkdir -p /etc/cloudflared
    
    # Log in to Cloudflare
    info "You will be redirected to Cloudflare authorization in your browser."
    cloudflared tunnel login
    
    # Copy cert.pem to /etc/cloudflared/
    if [ -f ~/.cloudflared/cert.pem ]; then
        sudo cp ~/.cloudflared/cert.pem /etc/cloudflared/
        sudo chmod 600 /etc/cloudflared/cert.pem
    else
        error "cert.pem file not found. Make sure Cloudflare login was successful."
        exit 1
    fi
    
    # Create tunnel
    read -p "Enter a name for the Cloudflare tunnel [n8n-tunnel]: " tunnel_name
    tunnel_name=${tunnel_name:-n8n-tunnel}
    
    # Check if tunnel with this name already exists
    info "Checking if tunnel named ${tunnel_name} already exists..."
    if cloudflared tunnel list | grep -q "${tunnel_name}"; then
        warning "Tunnel ${tunnel_name} already exists."
        # Get tunnel ID - only first matching result
        tunnel_id=$(cloudflared tunnel list | grep "${tunnel_name}" | head -n 1 | awk '{print $1}')
        # Ensure ID is correct and appears only once
        tunnel_id=$(echo "$tunnel_id" | tr -d '\n' | grep -o '[a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}')
        info "Using existing tunnel with ID: ${tunnel_id}"
    else
        info "Creating new tunnel: ${tunnel_name}"
        # Save full command output to temporary file
        cloudflared tunnel create ${tunnel_name} > /tmp/tunnel_create_output.txt
        
        # Try to extract tunnel ID using exact UUID pattern
        tunnel_id=$(cat /tmp/tunnel_create_output.txt | grep -o '[a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}' | head -n 1)
        
        # If tunnel ID not found, display full output
        if [ -z "$tunnel_id" ]; then
            error "Failed to extract tunnel ID."
            echo "Full command output:"
            cat /tmp/tunnel_create_output.txt
            
            # Ask user to manually provide tunnel ID
            read -p "Enter the tunnel ID displayed above: " manual_tunnel_id
            
            if [[ "$manual_tunnel_id" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
                tunnel_id="$manual_tunnel_id"
            else
                error "Provided tunnel ID has invalid format. Installation aborted."
                exit 1
            fi
        fi
        
        success "Tunnel created. ID: ${tunnel_id}"
        # Display ID again for verification
        info "Verified tunnel ID: ${tunnel_id}"
        # Remove temporary file
        rm -f /tmp/tunnel_create_output.txt
    fi
    
    # Find credentials file
    credential_file=$(find_credential_file "$tunnel_id")
    
    # If still not found, ask user to manually specify
    if [ -z "$credential_file" ] || [ ! -f "$credential_file" ]; then
        error "Tunnel credentials file not found."
        read -p "Enter the full path to the JSON credentials file: " manual_cred_file
        
        if [ -f "$manual_cred_file" ]; then
            credential_file="$manual_cred_file"
        else
            error "File $manual_cred_file does not exist. Installation aborted."
            exit 1
        fi
    fi
    
    # Clean tunnel ID of potential newline characters
    # Additionally ensure tunnel ID appears only once (no duplicates)
    tunnel_id=$(echo "$tunnel_id" | tr -d '\n' | grep -o '[a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}')
    domain_name=$(echo "$domain_name" | tr -d '\n')
    clean_filename="${tunnel_id}.json"
    
    # Additional tunnel ID verification
    info "Verifying tunnel ID correctness: ${tunnel_id}"
    if [[ ! "$tunnel_id" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
        error "Tunnel ID has invalid format. Enter correct ID manually."
        read -p "Correct tunnel ID (format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx): " tunnel_id
        # Re-clean entered ID
        tunnel_id=$(echo "$tunnel_id" | tr -d '\n' | grep -o '[a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}')
        if [[ ! "$tunnel_id" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
            error "Still invalid ID format. Installation aborted."
            exit 1
        fi
        clean_filename="${tunnel_id}.json"
    fi
    
    # Copy credentials file to /etc/cloudflared/ and set appropriate permissions
    info "Copying credentials file $credential_file to /etc/cloudflared/$clean_filename"
    
    # Remove old file if it exists to avoid copying issues
    sudo rm -f "/etc/cloudflared/$clean_filename"
    
    # Copy file
    sudo cp -f "$credential_file" "/etc/cloudflared/$clean_filename"
    sudo chmod 600 "/etc/cloudflared/$clean_filename"
    
    # Check if file was copied correctly
    if [ ! -f "/etc/cloudflared/$clean_filename" ]; then
        error "Failed to create credentials file. Installation aborted."
        exit 1
    fi
    
    # Create configuration file with proper YAML formatting
    info "Creating configuration file with correct YAML formatting..."
    
    # Remove old configuration file if it exists
    sudo rm -f /etc/cloudflared/config.yml
    
    # Display values before creating file (for verification)
    info "Tunnel ID: ${tunnel_id}"
    info "Credentials filename: ${clean_filename}"
    info "Domain: ${domain_name}"
    
    # Create new file using single echo commands
    echo "tunnel: ${tunnel_id}" | sudo tee /etc/cloudflared/config.yml > /dev/null
    echo "credentials-file: /etc/cloudflared/${clean_filename}" | sudo tee -a /etc/cloudflared/config.yml > /dev/null
    echo "ingress:" | sudo tee -a /etc/cloudflared/config.yml > /dev/null
    echo "  - hostname: ${domain_name}" | sudo tee -a /etc/cloudflared/config.yml > /dev/null
    echo "    service: http://192.168.0.178:8443" | sudo tee -a /etc/cloudflared/config.yml > /dev/null
    echo "  - service: http_status:404" | sudo tee -a /etc/cloudflared/config.yml > /dev/null
    
    # Check configuration file contents
    info "Contents of created configuration file:"
    cat /etc/cloudflared/config.yml
    
    # Set appropriate permissions
    sudo chmod 644 /etc/cloudflared/config.yml
    
    # Verify YAML file correctness
    info "Verifying configuration file correctness..."
    
    # Try to use cloudflared command to check file validity
    if cloudflared tunnel ingress validate --config /etc/cloudflared/config.yml 2>&1 | grep -q "error parsing"; then
        error "Configuration file verification failed."
        warning "There appears to be a problem with YAML formatting."
        
        # Display current file contents
        info "Current contents of config.yml file:"
        cat /etc/cloudflared/config.yml
        
        read -p "Do you want to use nano editor to manually edit the file now? (y/n): " edit_confirm
        if [[ "$edit_confirm" =~ ^[yY] ]]; then
            sudo nano /etc/cloudflared/config.yml
            info "File edited. Let's check if it's correct..."
            if cloudflared tunnel ingress validate --config /etc/cloudflared/config.yml 2>&1 | grep -q "error parsing"; then
                error "There are still issues with the configuration file."
                warning "You will need to fix it manually later."
            else
                success "Configuration file fixed manually and is now correct."
            fi
        else
            warning "Continuing installation, but the tunnel may not work correctly until the configuration file is fixed."
        fi
    else
        success "Configuration file is correct."
    fi
    
    # Create DNS record
    cloudflared tunnel route dns ${tunnel_name} ${domain_name}
    
    success "Cloudflare Tunnel configuration completed in /etc/cloudflared/config.yml."
}

# Function to manually run Cloudflare tunnel
run_cloudflare_tunnel_manually() {
    info "Starting Cloudflare tunnel manually..."
    
    # Check if configuration file exists
    if [ ! -f /etc/cloudflared/config.yml ]; then
        error "Configuration file not found. Configure the tunnel first."
        return 1
    fi
    
    # Run tunnel in background
    nohup cloudflared tunnel --config /etc/cloudflared/config.yml run > ~/cloudflared.log 2>&1 &
    
    # Save process PID
    echo $! > ~/cloudflared.pid
    
    success "Cloudflare tunnel started manually. Logs: ~/cloudflared.log"
    info "To stop the tunnel, use: kill \$(cat ~/cloudflared.pid)"
}

# Function to configure Cloudflared as a service
setup_cloudflared_service() {
    info "Configuring Cloudflared as a service..."
    
    # Check if configuration file exists
    if [ ! -f /etc/cloudflared/config.yml ]; then
        error "Configuration file /etc/cloudflared/config.yml not found. Configure the tunnel first."
        exit 1
    fi
    
    # Find tunnel ID based on configuration file
    tunnel_id=$(grep -oP '(?<=tunnel: )([a-f0-9-]+)' /etc/cloudflared/config.yml)
    tunnel_id=$(echo "$tunnel_id" | tr -d '\n')
    
    # Verify credentials file exists
    credentials_file=$(grep -oP '(?<=credentials-file: )(.+)' /etc/cloudflared/config.yml)
    
    if [ ! -f "$credentials_file" ]; then
        error "Credentials file does not exist: $credentials_file"
        
        # Try to fix by finding appropriate file
        info "Trying to find credentials file..."
        found_file=$(find_credential_file "$tunnel_id")
        
        if [ -n "$found_file" ] && [ -f "$found_file" ]; then
            clean_filename="${tunnel_id}.json"
            info "Found credentials file: $found_file"
            sudo cp -f "$found_file" "/etc/cloudflared/$clean_filename"
            sudo chmod 600 "/etc/cloudflared/$clean_filename"
            sudo sed -i "s|credentials-file: .*|credentials-file: /etc/cloudflared/$clean_filename|" /etc/cloudflared/config.yml
            success "Updated configuration file."
        else
            # Ask for manual file specification
            read -p "Enter the full path to the JSON credentials file: " manual_cred_file
            
            if [ -f "$manual_cred_file" ]; then
                clean_filename="${tunnel_id}.json"
                sudo cp -f "$manual_cred_file" "/etc/cloudflared/$clean_filename"
                sudo chmod 600 "/etc/cloudflared/$clean_filename"
                sudo sed -i "s|credentials-file: .*|credentials-file: /etc/cloudflared/$clean_filename|" /etc/cloudflared/config.yml
                success "Updated configuration file."
            else
                error "Failed to find credentials file. Installation aborted."
                exit 1
            fi
        fi
    fi
    
    # Create systemd service file
    sudo mkdir -p /etc/systemd/system
    cat > /tmp/cloudflared.service << EOF
[Unit]
Description=cloudflared
After=network.target

[Service]
TimeoutStartSec=0
Type=simple
User=root
ExecStart=/usr/local/bin/cloudflared --config /etc/cloudflared/config.yml tunnel run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    
    sudo cp /tmp/cloudflared.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable cloudflared
    sudo systemctl start cloudflared
    
    # Check status with delay
    sleep 2
    if sudo systemctl is-active cloudflared > /dev/null 2>&1; then
        success "Cloudflared started."
    else
        error "Cloudflared did not start. Check logs: sudo journalctl -u cloudflared"
        warning "You can try starting it manually: sudo cloudflared tunnel --config /etc/cloudflared/config.yml run"
        warning "Continuing installation, but you must resolve this issue later."
        
        # Offer manual start option
        info "Do you want to start the tunnel manually (not as systemd service)?"
        if confirm; then
            run_cloudflare_tunnel_manually
        fi
    fi
}

# Function to configure automatic backups
configure_backups() {
    info "Configuring automatic backups..."
    
    # Create backup script
    cat > ~/backup-n8n.sh << EOF
#!/bin/bash
BACKUP_DIR="/root/backups"
DATE=\$(date +%Y-%m-%d)
BACKUP_LOG="\$BACKUP_DIR/backup_history.log"

# Create backup directory if it doesn't exist
mkdir -p \$BACKUP_DIR

echo "Starting backup creation \$(date)" >> \$BACKUP_LOG

# PostgreSQL database backup
cd ~/n8n
docker-compose exec -T postgres pg_dump -U ${db_user} n8n > \$BACKUP_DIR/n8n_postgres_backup_\$DATE.sql
if [ \$? -eq 0 ]; then
    echo "✓ PostgreSQL database backup completed successfully" >> \$BACKUP_LOG
else
    echo "✗ Error creating PostgreSQL database backup" >> \$BACKUP_LOG
fi

# n8n configuration data backup
tar -czvf \$BACKUP_DIR/n8n_data_backup_\$DATE.tar.gz ~/.n8n
if [ \$? -eq 0 ]; then
    echo "✓ Configuration data backup completed successfully" >> \$BACKUP_LOG
else
    echo "✗ Error creating configuration data backup" >> \$BACKUP_LOG
fi

# Cloudflare configuration backup
sudo tar -czvf \$BACKUP_DIR/cloudflared_backup_\$DATE.tar.gz /etc/cloudflared
if [ \$? -eq 0 ]; then
    echo "✓ Cloudflare configuration backup completed successfully" >> \$BACKUP_LOG
else
    echo "✗ Error creating Cloudflare configuration backup" >> \$BACKUP_LOG
fi

# Create single archive containing all backups from the day
tar -czvf \$BACKUP_DIR/n8n_full_backup_\$DATE.tar.gz \$BACKUP_DIR/n8n_postgres_backup_\$DATE.sql \$BACKUP_DIR/n8n_data_backup_\$DATE.tar.gz \$BACKUP_DIR/cloudflared_backup_\$DATE.tar.gz
if [ \$? -eq 0 ]; then
    echo "✓ Full backup created successfully" >> \$BACKUP_LOG
else
    echo "✗ Error creating full backup" >> \$BACKUP_LOG
fi

# Remove backups older than 30 days
echo "Removing old backups..." >> \$BACKUP_LOG
find \$BACKUP_DIR -name "n8n_postgres_backup_*.sql" -type f -mtime +30 -delete
find \$BACKUP_DIR -name "n8n_data_backup_*.tar.gz" -type f -mtime +30 -delete
find \$BACKUP_DIR -name "cloudflared_backup_*.tar.gz" -type f -mtime +30 -delete
find \$BACKUP_DIR -name "n8n_full_backup_*.tar.gz" -type f -mtime +30 -delete

# Backup completion info
echo "Backup completed \$(date)" >> \$BACKUP_LOG
echo "--------------------------------------" >> \$BACKUP_LOG
EOF
    
    chmod +x ~/backup-n8n.sh
    
    # Create restore script
    cat > ~/restore-n8n.sh << EOF
#!/bin/bash

# Script to restore n8n from backup
# Usage: ./restore-n8n.sh YYYY-MM-DD

if [ -z "\$1" ]; then
  echo "Provide backup date in YYYY-MM-DD format"
  exit 1
fi

BACKUP_DIR="/root/backups"
DATE=\$1

# Check if backup exists
if [ ! -f "\$BACKUP_DIR/n8n_postgres_backup_\$DATE.sql" ] || [ ! -f "\$BACKUP_DIR/n8n_data_backup_\$DATE.tar.gz" ]; then
  echo "Backup from date \$DATE does not exist!"
  exit 1
fi

# Stop services
cd ~/n8n
docker-compose down
sudo systemctl stop cloudflared

# Restore Cloudflare configuration
if [ -f "\$BACKUP_DIR/cloudflared_backup_\$DATE.tar.gz" ]; then
  sudo tar -xzvf "\$BACKUP_DIR/cloudflared_backup_\$DATE.tar.gz" -C /
  echo "Cloudflare configuration restored."
fi

# Restore database
docker-compose up -d postgres
sleep 5
cat "\$BACKUP_DIR/n8n_postgres_backup_\$DATE.sql" | docker-compose exec -T postgres psql -U ${db_user} n8n
docker-compose down

# Restore n8n configuration files
rm -rf ~/.n8n.bak
mv ~/.n8n ~/.n8n.bak  # Backup current configuration
tar -xzvf "\$BACKUP_DIR/n8n_data_backup_\$DATE.tar.gz" -C /

# Start services
sudo systemctl start cloudflared
docker-compose up -d

echo "Restore from backup \$DATE completed"
EOF
    
    chmod +x ~/restore-n8n.sh
    
    # Add cron job
    (crontab -l 2>/dev/null | grep -v "backup-n8n.sh"; echo "0 3 * * * /root/backup-n8n.sh > /root/backup.log 2>&1") | crontab -
    
    success "Automatic backup configuration completed."
}

# Function to start services
start_services() {
    info "Starting services..."
    
    # First configure Cloudflared
    setup_cloudflared_service
    
    # Check if Docker daemon is running
    if ! docker info &>/dev/null; then
        error "Docker is not running or lacks permissions. Attempting to fix..."
        
        # Try to fix Docker issue
        info "Checking Docker directory permissions..."
        sudo mkdir -p /var/lib/docker/network/files
        sudo chown -R root:root /var/lib/docker
        
        info "Restarting Docker service..."
        sudo systemctl restart docker
        sleep 5
        
        # Check if Docker works after restart
        if ! docker info &>/dev/null; then
            error "Docker still not working correctly."
            warning "System restart is probably needed."
            read -p "Do you want to restart the system now? (y/n): " restart_now
            if [[ "$restart_now" =~ ^[yY] ]]; then
                # Save flag so script knows to continue after restart
                touch ~/.n8n_install_progress
                info "Restarting system. Run the script again after restart."
                sudo reboot
                exit 0
            else
                error "Cannot continue without working Docker. Installation aborted."
                exit 1
            fi
        else
            success "Docker fixed after service restart."
        fi
    fi
    
    # Start n8n
    cd ~/n8n
    info "Starting n8n containers..."
    docker-compose down
    docker-compose up -d
    
    # Check status
    if docker-compose ps | grep -q "n8n"; then
        success "n8n started."
    else
        error "n8n did not start. Check logs: docker-compose logs"
        warning "Displaying logs..."
        docker-compose logs
        
        # Try to fix Docker network issues
        warning "Attempting to fix Docker network issues..."
        docker network prune -f
        info "Removed unused Docker networks. Trying to restart n8n..."
        
        # Retry starting
        docker-compose up -d
        
        sleep 5
        if docker-compose ps | grep -q "n8n"; then
            success "n8n started after network fix."
        else
            error "Still unable to start n8n."
            configure_backups
            show_final_info
        fi
    fi
}

# Function to display final information
show_final_info() {
    domain_name=$(grep -oP '(?<=hostname: )(.+)' /etc/cloudflared/config.yml)
    
    echo -e "\n${GREEN}==================================================${NC}"
    echo -e "${GREEN}n8n installation completed successfully!${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${BLUE}Guide from:${NC} www.przewodnikai.pl"
    echo -e "${BLUE}YouTube Channel:${NC} https://www.youtube.com/@lukaszpodgorski"
    
    echo -e "\nYour n8n server is available at:"
    echo -e "${BLUE}https://${domain_name}${NC}"
    echo -e "\nCreate an admin account on first launch."
    echo -e "\nAdditional information:"
    echo -e "- n8n configuration files: ~/n8n/docker-compose.yml"
    echo -e "- Cloudflare configuration: /etc/cloudflared/config.yml"
    echo -e "- Backup script: ~/backup-n8n.sh (runs daily at 3:00 AM)"
    echo -e "- Restore script: ~/restore-n8n.sh (usage: ./restore-n8n.sh YYYY-MM-DD)"
    
    echo -e "\n${YELLOW}IMPORTANT: Perform a system restart to ensure all services start correctly.${NC}"
    echo -e "${YELLOW}You can do this with: sudo reboot${NC}"
    
    echo -e "\n${BLUE}Thank you for using our guide!${NC}"
    echo -e "${BLUE}More materials at:${NC} www.przewodnikai.pl"
    echo -e "${BLUE}and on YouTube:${NC} https://www.youtube.com/@lukaszpodgorski"
    echo -e "\n${GREEN}==================================================${NC}"
}

# Main script function
main() {
    check_raspberry_pi
    check_privileges
    
    echo -e "\n${GREEN}==================================================${NC}"
    echo -e "${GREEN}Automatic n8n installer for Raspberry Pi${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${BLUE}Author:${NC} Łukasz Podgórski & Anthropic Claude"
    echo -e "${BLUE}Version:${NC} 2.6 (simplified permissions)"
    echo -e "${BLUE}Guide from:${NC} www.przewodnikai.pl"
    echo -e "${BLUE}YouTube Channel:${NC} https://www.youtube.com/@lukaszpodgorski"
    echo -e "\n${YELLOW}This script will install n8n and configure access via Cloudflare Tunnel.${NC}"
    
    if ! confirm; then
        exit 0
    fi
    
    # Check if this is a continuation after system restart after Docker installation
    if [ -f ~/.docker_fresh_install ]; then
        info "Detected continuation after system restart post-Docker installation."
        
        # Check if Docker is working correctly
        if ! docker info &>/dev/null; then
            error "Docker not working correctly even after restart. Check Docker installation manually."
            exit 1
        fi
        
        # Remove Docker fresh install flag
        rm -f ~/.docker_fresh_install
        
        success "Docker working correctly. Continuing installation..."
        
        # Proceed to Docker Compose installation (may be needed after restart)
        install_docker_compose
        configure_n8n
        install_cloudflared
        configure_cloudflare_tunnel
        start_services
        configure_backups
        show_final_info
    elif [ -f ~/.n8n_install_progress ]; then
        # If n8n installation progress flag exists (restart due to Docker issues)
        info "Detected installation continuation after system restart (n8n startup issues)."
        
        # Remove progress flag
        rm -f ~/.n8n_install_progress
        
        # Check if Docker is working correctly
        if ! docker info &>/dev/null; then
            error "Docker still not working correctly. Please check Docker installation manually."
            exit 1
        fi
        
        success "Docker working correctly. Continuing n8n installation..."
        
        # Try to start n8n and complete installation
        cd ~/n8n
        docker network prune -f
        docker-compose down
        docker-compose up -d
        
        # Check status
        if docker-compose ps | grep -q "n8n" && docker-compose ps | grep -q "Up"; then
            success "n8n started successfully after system restart."
            configure_backups
            show_final_info
        else
            error "Still having issues starting n8n."
            configure_backups
            show_final_info
        fi
    else
        # Standard installation flow
        update_system
        install_docker
        install_docker_compose
        configure_n8n
        install_cloudflared
        configure_cloudflare_tunnel
        start_services
        configure_backups
        show_final_info
    fi
}

# Run the script
main
