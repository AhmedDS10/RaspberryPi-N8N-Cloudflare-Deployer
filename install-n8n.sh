#!/bin/bash

# --- Colors for better terminal readability ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

db_user="user"             # Default
db_password="n8n_password" # Default

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

confirm() {
    read -p "Do you want to continue? (y/n): " response
    [[ "$response" =~ ^[yY] ]] && return 0 || return 1
}

# --- Helper functions ----------------------------------------------------------
check_raspberry_pi() {
    if [[ ! -f /proc/device-tree/model ]] || ! grep -q "Raspberry Pi" /proc/device-tree/model; then
        error "This script is designed to run on a Raspberry Pi."
        exit 1
    fi
}

check_privileges() {
    if ! groups | grep -qE "sudo|root"; then
        error "This script requires root or sudo privileges."
        exit 1
    fi
}

update_system() {
    info "Updating system packages..."
    sudo apt update && sudo apt upgrade -y
    success "System updated."
}

install_docker() {
    info "Installing Docker..."
    if ! command -v docker &>/dev/null; then
        curl -sSL https://get.docker.com | sh
        sudo usermod -aG docker "$USER"
        success "Docker installed. A reboot is required."

        touch ~/.docker_fresh_install
        warning "System must reboot for changes to take effect."
        info "Run the script again after reboot."
        read -p "Reboot now? (y/n): " reboot_now
        [[ "$reboot_now" =~ ^[yY] ]] && sudo reboot && exit 0
        warning "Remember to reboot before continuing."
        exit 0
    else
        success "Docker is already installed."
    fi
}

install_docker_compose() {
    info "Installing Docker Compose..."
    if ! command -v docker-compose &>/dev/null; then
        sudo apt install -y docker-compose
        success "Docker Compose installed."
    else
        success "Docker Compose is already installed."
    fi
}

configure_n8n() {
    info "Configuring n8n..."

    read -p "Enter your domain for n8n (e.g. mydomain-n8n.com): " domain_name
    read -p "PostgreSQL password [n8n_password]: " db_password
    db_password=${db_password:-n8n_password}

    mkdir -p ~/n8n ~/.n8n
    sudo chown -R "$USER:$USER" ~/.n8n
    sudo chmod -R 755 ~/.n8n

    cat > ~/n8n/docker-compose.yml <<EOF

services:
  postgres:
    image: postgres:15.8
    restart: always
    environment:
      - POSTGRES_USER=${db_user}
      - POSTGRES_PASSWORD=${db_password}
      - POSTGRES_DB=n8n
      - TZ=Europe/Warsaw
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
      - N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE=true
      - TZ=Europe/Warsaw
      - WEBHOOK_URL=https://${domain_name}
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
    success "n8n configuration created at ~/n8n/docker-compose.yml"
}

install_cloudflared() {
    info "Installing cloudflared..."
    if ! command -v cloudflared &>/dev/null; then
        sudo mkdir -p /usr/local/bin
        cd /usr/local/bin
        sudo curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o cloudflared
        sudo chmod +x cloudflared
        success "cloudflared installed. Version: $(cloudflared --version)"
    else
        success "cloudflared already installed. Version: $(cloudflared --version)"
    fi
}

find_credential_file() {
    local tunnel_id=$1
    local credential_file=""
    local dirs=("/root/.cloudflared" "$HOME/.cloudflared")
    for dir in "${dirs[@]}"; do
        if [[ -d $dir ]]; then
            credential_file=$(find "$dir" -name "*.json" -type f | grep -i "$tunnel_id" | head -n 1)
            [[ -n $credential_file ]] && break
        fi
    done
    echo "$credential_file"
}

configure_cloudflare_tunnel() {
    info "Configuring Cloudflare Tunnel..."

    warning "You must have a domain already added to Cloudflare. If not, exit now."
    confirm || exit 1

    sudo mkdir -p /etc/cloudflared
    info "You will be redirected to authorize Cloudflare in your browser."
    cloudflared tunnel login

    [[ -f ~/.cloudflared/cert.pem ]] && sudo cp ~/.cloudflared/cert.pem /etc/cloudflared/ && sudo chmod 600 /etc/cloudflared/cert.pem || {
        error "cert.pem not found. Make sure login succeeded."
        exit 1
    }

    read -p "Enter a tunnel name [n8n-tunnel]: " tunnel_name
    tunnel_name=${tunnel_name:-n8n-tunnel}

    if cloudflared tunnel list | grep -q "$tunnel_name"; then
        warning "Tunnel $tunnel_name already exists."
        tunnel_id=$(cloudflared tunnel list | grep "$tunnel_name" | awk '{print $1}' | head -n1)
        info "Using existing tunnel ID: $tunnel_id"
    else
        info "Creating new tunnel: $tunnel_name"
        cloudflared tunnel create "$tunnel_name" > /tmp/tunnel_create_output.txt
        tunnel_id=$(grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' /tmp/tunnel_create_output.txt | head -n1)
        [[ -z $tunnel_id ]] && {
            error "Could not extract tunnel ID."
            cat /tmp/tunnel_create_output.txt
            read -p "Enter tunnel ID manually: " tunnel_id
        }
        rm -f /tmp/tunnel_create_output.txt
    fi

    credential_file=$(find_credential_file "$tunnel_id")
    [[ -z $credential_file ]] && {
        error "Credential file not found."
        read -p "Enter full path to JSON credential file: " credential_file
    }

    clean_filename="${tunnel_id}.json"
    sudo rm -f "/etc/cloudflared/$clean_filename"
    sudo cp "$credential_file" "/etc/cloudflared/$clean_filename"
    sudo chmod 600 "/etc/cloudflared/$clean_filename"

    # Generate config.yml
    sudo tee /etc/cloudflared/config.yml >/dev/null <<EOF
tunnel: ${tunnel_id}
credentials-file: /etc/cloudflared/${clean_filename}
ingress:
  - hostname: ${domain_name}
    service: http://localhost:8443
  - service: http_status:404
EOF
    sudo chmod 644 /etc/cloudflared/config.yml

    cloudflared tunnel route dns "$tunnel_name" "$domain_name"
    success "Cloudflare Tunnel configured at /etc/cloudflared/config.yml"
}

setup_cloudflared_service() {
    info "Setting up cloudflared as systemd service..."
    [[ ! -f /etc/cloudflared/config.yml ]] && {
        error "config.yml not found. Configure the tunnel first."
        exit 1
    }

    cat >/tmp/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
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
    sudo systemctl enable --now cloudflared
    sleep 2
    sudo systemctl is-active cloudflared >/dev/null \
        && success "cloudflared service started." \
        || error "cloudflared service failed to start. Check with: sudo journalctl -u cloudflared"
}

configure_backups() {
    info "Configuring automatic daily backups..."

    mkdir -p ~/backups
    cat > ~/backup-n8n.sh <<EOF
#!/bin/bash
BACKUP_DIR="\$HOME/backups"
DATE=\$(date +%Y-%m-%d)
mkdir -p "\$BACKUP_DIR"

cd ~/n8n
docker-compose exec -T postgres pg_dump -U ${db_user} n8n > "\$BACKUP_DIR/n8n_postgres_\$DATE.sql"
tar -czf "\$BACKUP_DIR/n8n_data_\$DATE.tar.gz" -C ~ .n8n
sudo tar -czf "\$BACKUP_DIR/cloudflared_\$DATE.tar.gz" -C / etc/cloudflared

tar -czf "\$BACKUP_DIR/n8n_full_\$DATE.tar.gz" "\$BACKUP_DIR/n8n_postgres_\$DATE.sql" "\$BACKUP_DIR/n8n_data_\$DATE.tar.gz" "\$BACKUP_DIR/cloudflared_\$DATE.tar.gz"
find "\$BACKUP_DIR" -type f -mtime +30 -delete
EOF
    chmod +x ~/backup-n8n.sh

    cat > ~/restore-n8n.sh <<EOF
#!/bin/bash
[ -z "\$1" ] && { echo "Usage: ./restore-n8n.sh YYYY-MM-DD"; exit 1; }
DATE=\$1
BACKUP_DIR="\$HOME/backups"
cd ~/n8n
docker-compose down
sudo systemctl stop cloudflared
docker-compose up -d postgres
sleep 5
cat "\$BACKUP_DIR/n8n_postgres_\$DATE.sql" | docker-compose exec -T postgres psql -U ${db_user} n8n
docker-compose down
tar -xzf "\$BACKUP_DIR/n8n_data_\$DATE.tar.gz" -C /
sudo tar -xzf "\$BACKUP_DIR/cloudflared_\$DATE.tar.gz" -C /
sudo systemctl start cloudflared
docker-compose up -d
echo "Restore from \$DATE finished"
EOF
    chmod +x ~/restore-n8n.sh

    (crontab -l 2>/dev/null | grep -v backup-n8n.sh; echo "0 3 * * * ~/backup-n8n.sh >> ~/backup.log 2>&1") | crontab -
    success "Daily backups scheduled (03:00)."
}

start_services() {
    info "Starting services..."

    setup_cloudflared_service

    if ! docker info &>/dev/null; then
        error "Docker is not running. Attempting restart..."
        sudo systemctl restart docker
        sleep 5
        if ! docker info &>/dev/null; then
            error "Docker still failing. Reboot required."
            touch ~/.n8n_install_progress
            read -p "Reboot now? (y/n): " reboot_now
            [[ "$reboot_now" =~ ^[yY] ]] && sudo reboot && exit 0
            exit 1
        fi
    fi

    cd ~/n8n
    docker-compose down
    docker-compose up -d

    if docker-compose ps | grep -q "Up"; then
        success "n8n containers started."
    else
        error "n8n containers failed to start. See logs: docker-compose logs"
    fi
}

show_final_info() {
    domain_name=$(grep -oP '(?<=hostname: ).*' /etc/cloudflared/config.yml)
    echo -e "\n${GREEN}=================================================="
    echo -e "n8n installation completed successfully!"
    echo -e "==================================================${NC}"
    echo -e "Your n8n server is available at:"
    echo -e "${BLUE}https://${domain_name}${NC}"
    echo -e "\nOn first run create an admin account."
    echo -e "Configuration files:"
    echo "  - ~/n8n/docker-compose.yml"
    echo "  - /etc/cloudflared/config.yml"
    echo "  - ~/backup-n8n.sh (daily 03:00)"
    echo "  - ~/restore-n8n.sh (usage: ./restore-n8n.sh YYYY-MM-DD)"
    echo -e "\n${YELLOW}IMPORTANT: Reboot once to ensure all services start properly:${NC} sudo reboot"
}

main() {
    check_raspberry_pi
    check_privileges

    echo -e "\n${GREEN}=================================================="
    echo -e "Automatic n8n installer for Raspberry Pi"
    echo -e "==================================================${NC}"
    confirm || exit 0

    if [[ -f ~/.docker_fresh_install ]]; then
        rm ~/.docker_fresh_install
        install_docker_compose
        configure_n8n
        install_cloudflared
        configure_cloudflare_tunnel
        start_services
        configure_backups
        show_final_info
    elif [[ -f ~/.n8n_install_progress ]]; then
        rm ~/.n8n_install_progress
        start_services
        configure_backups
        show_final_info
    else
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

main
