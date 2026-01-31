#!/bin/bash
# =============================================================================
# Netboot Server - Start Script
# =============================================================================
# This script prepares and starts the Netboot Server:
#   1. Checks for required dependencies (Docker, Docker Compose)
#   2. Makes scripts executable
#   3. Prompts to change default password (if not already changed)
#   4. Runs initial setup (downloads bootloaders if needed)
#   5. Builds and starts the container
#
# Usage: ./start.sh
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "${BLUE}"
echo "==========================================="
echo "       N E T B O O T   S E R V E R"
echo "==========================================="
echo -e "${NC}"

# ---------------------------------------------------------------------------
# Step 1: Check Dependencies
# ---------------------------------------------------------------------------
echo -e "${BLUE}[1/5]${NC} Checking dependencies..."

MISSING_DEPS=0

# Check for Docker
if command -v docker &> /dev/null; then
    DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | tr -d ',')
    echo -e "  ${GREEN}✓${NC} Docker installed (v$DOCKER_VERSION)"
else
    echo -e "  ${RED}✗${NC} Docker not found"
    MISSING_DEPS=1
fi

# Check for Docker Compose (both standalone and plugin)
if command -v docker-compose &> /dev/null; then
    COMPOSE_VERSION=$(docker-compose --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo -e "  ${GREEN}✓${NC} Docker Compose installed (v$COMPOSE_VERSION)"
    COMPOSE_CMD="docker-compose"
elif docker compose version &> /dev/null; then
    COMPOSE_VERSION=$(docker compose version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo -e "  ${GREEN}✓${NC} Docker Compose plugin installed (v$COMPOSE_VERSION)"
    COMPOSE_CMD="docker compose"
else
    echo -e "  ${RED}✗${NC} Docker Compose not found"
    MISSING_DEPS=1
fi

# If dependencies are missing, show installation instructions
if [ $MISSING_DEPS -eq 1 ]; then
    echo ""
    echo -e "${YELLOW}Missing dependencies. Install them first:${NC}"
    echo ""
    echo "  Ubuntu/Debian:"
    echo "    sudo apt update"
    echo "    sudo apt install docker.io docker-compose-v2"
    echo "    sudo usermod -aG docker \$USER"
    echo "    # Log out and back in for group changes"
    echo ""
    echo "  Or install Docker Desktop: https://docs.docker.com/desktop/"
    echo ""
    exit 1
fi

echo ""

# ---------------------------------------------------------------------------
# Step 2: Make Scripts Executable
# ---------------------------------------------------------------------------
echo -e "${BLUE}[2/5]${NC} Making scripts executable..."

chmod +x scripts/*.sh 2>/dev/null || true
chmod +x scripts/lib/*.sh 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} Scripts are executable"
echo ""

# ---------------------------------------------------------------------------
# Step 3: Check/Change Default Password
# ---------------------------------------------------------------------------
echo -e "${BLUE}[3/5]${NC} Checking authentication configuration..."

USERS_FILE="$SCRIPT_DIR/config/auth/users.yml"
DEFAULT_HASH='$2b$12$yzMmlCNc9pTTujMwVVzmpul14SkgVCFWS5O/n6U9FlMDSJNFqEjzS'

if [ -f "$USERS_FILE" ]; then
    if grep -q "$DEFAULT_HASH" "$USERS_FILE"; then
        echo -e "  ${YELLOW}⚠${NC}  Default password detected (admin/netboot)"
        echo ""
        echo -e "${YELLOW}WARNING: You are using the default password!${NC}"
        echo "Anyone who knows the default can access your boot menu."
        echo ""
        read -p "Would you like to change the password now? [Y/n] " -n 1 -r
        echo ""

        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            echo ""
            read -p "Enter new username [admin]: " NEW_USERNAME
            NEW_USERNAME=${NEW_USERNAME:-admin}

            while true; do
                read -s -p "Enter new password: " NEW_PASSWORD
                echo ""
                read -s -p "Confirm password: " CONFIRM_PASSWORD
                echo ""

                if [ "$NEW_PASSWORD" = "$CONFIRM_PASSWORD" ]; then
                    if [ -z "$NEW_PASSWORD" ]; then
                        echo -e "${RED}Password cannot be empty. Try again.${NC}"
                    else
                        break
                    fi
                else
                    echo -e "${RED}Passwords don't match. Try again.${NC}"
                fi
            done

            # Generate bcrypt hash using Python (available in most systems)
            if command -v python3 &> /dev/null; then
                # Try to use bcrypt if available, otherwise use container
                NEW_HASH=$(python3 -c "
import sys
try:
    import bcrypt
    password = sys.argv[1].encode('utf-8')
    hash = bcrypt.hashpw(password, bcrypt.gensalt(rounds=12))
    print(hash.decode('utf-8'))
except ImportError:
    print('NEED_CONTAINER')
" "$NEW_PASSWORD" 2>/dev/null)

                if [ "$NEW_HASH" = "NEED_CONTAINER" ]; then
                    echo "  Generating password hash (building container first)..."
                    $COMPOSE_CMD build --quiet
                    NEW_HASH=$($COMPOSE_CMD run --rm -e PASSWORD="$NEW_PASSWORD" netboot python3 -c "
import bcrypt, os
password = os.environ['PASSWORD'].encode('utf-8')
hash = bcrypt.hashpw(password, bcrypt.gensalt(rounds=12))
print(hash.decode('utf-8'))
" 2>/dev/null)
                fi
            else
                echo "  Generating password hash (building container first)..."
                $COMPOSE_CMD build --quiet
                NEW_HASH=$($COMPOSE_CMD run --rm -e PASSWORD="$NEW_PASSWORD" netboot python3 -c "
import bcrypt, os
password = os.environ['PASSWORD'].encode('utf-8')
hash = bcrypt.hashpw(password, bcrypt.gensalt(rounds=12))
print(hash.decode('utf-8'))
" 2>/dev/null)
            fi

            if [ -n "$NEW_HASH" ] && [ "$NEW_HASH" != "NEED_CONTAINER" ]; then
                # Update users.yml
                cat > "$USERS_FILE" << EOF
# Netboot Server - Local Users
#
# To regenerate password hash, run: ./start.sh
# Or: python3 auth/hash-password.py
#
users:
  - username: $NEW_USERNAME
    password_hash: "$NEW_HASH"
EOF
                echo -e "  ${GREEN}✓${NC} Password updated for user '$NEW_USERNAME'"
            else
                echo -e "  ${RED}✗${NC} Failed to generate password hash"
                echo "  You can change it manually later with: python3 auth/hash-password.py"
            fi
        else
            echo -e "  ${YELLOW}⚠${NC}  Keeping default password (change it later!)"
        fi
    else
        echo -e "  ${GREEN}✓${NC} Custom password configured"
    fi
else
    echo -e "  ${RED}✗${NC} Users file not found: $USERS_FILE"
fi

echo ""

# ---------------------------------------------------------------------------
# Step 4: Run Setup (download bootloaders if needed)
# ---------------------------------------------------------------------------
echo -e "${BLUE}[4/5]${NC} Running initial setup..."

# Check if .env exists
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    if [ -f "$SCRIPT_DIR/.env.example" ]; then
        cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
        echo -e "  ${YELLOW}!${NC} Created .env from .env.example"
        echo -e "  ${YELLOW}!${NC} Edit .env and set TFTP_SERVER_IP to your server's IP"
        echo ""
        read -p "Enter your server's IP address [192.168.1.100]: " SERVER_IP
        SERVER_IP=${SERVER_IP:-192.168.1.100}
        sed -i "s/TFTP_SERVER_IP=.*/TFTP_SERVER_IP=$SERVER_IP/" "$SCRIPT_DIR/.env"
        echo -e "  ${GREEN}✓${NC} Set TFTP_SERVER_IP=$SERVER_IP"
    fi
else
    echo -e "  ${GREEN}✓${NC} .env file exists"
fi

# Run setup.sh if bootloaders don't exist
if [ ! -f "$SCRIPT_DIR/tftp/ipxe.efi" ] || [ ! -f "$SCRIPT_DIR/tftp/undionly.kpxe" ]; then
    echo "  Downloading iPXE bootloaders..."
    bash "$SCRIPT_DIR/scripts/setup.sh"
else
    echo -e "  ${GREEN}✓${NC} Bootloaders already downloaded"
fi

echo ""

# ---------------------------------------------------------------------------
# Step 5: Build and Start Container
# ---------------------------------------------------------------------------
echo -e "${BLUE}[5/5]${NC} Building and starting container..."

$COMPOSE_CMD up -d --build

echo ""
echo -e "${GREEN}==========================================="
echo "       Netboot Server is running!"
echo "==========================================="
echo -e "${NC}"
echo "  Web interface: http://$(grep TFTP_SERVER_IP .env | cut -d= -f2):8080"
echo "  Health check:  http://$(grep TFTP_SERVER_IP .env | cut -d= -f2):8080/health"
echo ""
echo "  View logs:     $COMPOSE_CMD logs -f"
echo "  Stop server:   $COMPOSE_CMD down"
echo ""
echo "  Next steps:"
echo "    1. Add ISO images to the images/ folder"
echo "    2. Run: ./scripts/prepare-images.sh"
echo "    3. PXE boot a client on your network"
echo ""
