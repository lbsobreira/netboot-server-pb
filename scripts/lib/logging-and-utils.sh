#!/bin/bash
# =============================================================================
# Netboot Server - Logging and Utility Functions
# =============================================================================
# Provides colored logging output (info, warn, error) and common utilities.
# Source this file from other scripts.
# =============================================================================

# Colours for output (disabled in log file, enabled on tty)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
