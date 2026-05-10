#!/usr/bin/env bash

################################################################################
# TorMan - Advanced Tor Management Script
# A professional Bash script for managing Tor services, configuration,
# and onion services with a modern gum-based TUI.
#
# Author: Security Operations
# License: MIT
# Requirements: gum, tor, curl, netcat-openbsd
################################################################################

set -euo pipefail

# Configuration (overridable via environment variables)
TORRC_PATH="${TORRC_PATH:-/etc/tor/torrc}"
TOR_DATA_DIR="${TOR_DATA_DIR:-/var/lib/tor}"
readonly TORRC_PATH TOR_DATA_DIR
readonly CONTROL_PORT=9051
readonly SOCKS_PORT=9050
readonly CONFIG_BEGIN_MARKER="# BEGIN TORMAN_CONFIG"
readonly CONFIG_END_MARKER="# END TORMAN_CONFIG"

# Colors for fallback mode
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

################################################################################
# Tor User Detection
################################################################################

get_tor_user() {
    local tor_user=""
    local tor_pid
    tor_pid=$(pgrep -x tor 2>/dev/null | head -n1)
    if [[ -n "$tor_pid" ]]; then
        tor_user=$(ps -o user= -p "$tor_pid" 2>/dev/null | tr -d ' ')
    fi
    if [[ -z "$tor_user" ]]; then
        if id debian-tor &>/dev/null; then
            tor_user="debian-tor"
        else
            tor_user="tor"
        fi
    fi
    echo "$tor_user"
}

readonly TOR_USER=$(get_tor_user)

################################################################################
# Dependency Management
################################################################################

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}ERROR:${NC} This script must be run as root or with sudo."
        exit 1
    fi
}

check_gum() {
    if ! command -v gum &> /dev/null; then
        echo -e "${YELLOW}gum is not installed.${NC}"
        echo "gum is required for the interactive interface."
        echo "Install it from: https://github.com/charmbracelet/gum"
        echo ""
        read -p "Would you like to install gum now? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            install_gum
        else
            echo "Exiting. Please install gum manually."
            exit 1
        fi
    fi
}

install_gum() {
    echo -e "${YELLOW}Installing gum...${NC}"
    
    local install_success=0
    
    if command -v apt &> /dev/null; then
        # Try installing from default repositories first
        apt update && apt install -y gum && install_success=1
    elif command -v dnf &> /dev/null; then
        dnf install -y gum && install_success=1
    else
        echo -e "${RED}Unsupported package manager. Please install gum manually.${NC}"
        exit 1
    fi

    if [[ $install_success -eq 1 ]] && command -v gum &> /dev/null; then
        echo -e "${GREEN}✓ gum installed successfully!${NC}"
    else
        echo -e "${RED}Failed to install gum. Please install it manually.${NC}"
        exit 1
    fi
}

check_dependencies() {
    local missing_deps=()
    
    for cmd in tor curl nc; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        gum style --border double --padding "1 2" --foreground 226 \
            "Missing Dependencies" \
            "" \
            "The following packages are required:" \
            "$(printf '  • %s\n' "${missing_deps[@]}")"
        
        if gum confirm "Install missing dependencies?"; then
            install_dependencies "${missing_deps[@]}"
        else
            gum style --foreground 196 "Cannot proceed without required dependencies."
            exit 1
        fi
    fi
}

install_dependencies() {
    local deps=("$@")
    local install_cmd=""
    
    # Map commands to package names
    local -A pkg_map=(
        [nc]="netcat-openbsd"
        [tor]="tor"
        [curl]="curl"
    )
    
    local packages=()
    for dep in "${deps[@]}"; do
        packages+=("${pkg_map[$dep]:-$dep}")
    done
    
    gum spin --spinner dot --title "Installing dependencies..." -- \
        apt update && apt install -y "${packages[@]}"
    
    gum style --foreground 82 "✓ Dependencies installed successfully!"
    sleep 1
}

check_torrc() {
    if [[ ! -f "$TORRC_PATH" ]]; then
        gum style --foreground 196 "ERROR: torrc not found at $TORRC_PATH"
        gum style --foreground 226 "Please install Tor properly."
        exit 1
    fi
}

################################################################################
# Configuration Management - Safe Block-Based Editing
################################################################################

ensure_config_block() {
    # Check if our config block exists, if not create it
    if ! grep -q "$CONFIG_BEGIN_MARKER" "$TORRC_PATH"; then
        gum style --foreground 226 "Initializing TorMan configuration block..."
        cat >> "$TORRC_PATH" <<EOF

$CONFIG_BEGIN_MARKER
# This section is managed by TorMan. Do not edit manually.
# Changes made through TorMan will be placed here.
SocksPort $SOCKS_PORT
$CONFIG_END_MARKER
EOF
        gum style --foreground 82 "✓ Configuration block created."
        sleep 1
    fi
}

get_config_value() {
    local key="$1"
    local default="$2"
    
    # Extract value from our managed block only
    local value
    value=$(sed -n "/$CONFIG_BEGIN_MARKER/,/$CONFIG_END_MARKER/p" "$TORRC_PATH" | \
            grep -E "^${key}\s" | awk '{print $2}' | tail -n1)
    
    echo "${value:-$default}"
}

set_config_value() {
    local key="$1"
    local value="$2"
    
    backup_torrc
    local original_perms
    original_perms=$(get_file_permissions)
    
    ensure_config_block
    
    local tmp_file
    tmp_file=$(mktemp)
    trap 'rm -f "$tmp_file"' EXIT
    
    # Process the file:
    # 1. Copy everything before our block
    # 2. Recreate our block with the new value
    # 3. Copy everything after our block
    
    awk -v begin="$CONFIG_BEGIN_MARKER" \
        -v end="$CONFIG_END_MARKER" \
        -v key="$key" \
        -v value="$value" '
        BEGIN { in_block=0; block_content="" }
        
        # Before block starts
        $0 ~ begin {
            print $0
            in_block=1
            next
        }
        
        # Inside block - collect lines
        in_block && $0 !~ end {
            # Skip lines matching our key (we will add it fresh)
            if ($0 !~ "^"key"\\s") {
                block_content = block_content $0 "\n"
            }
            next
        }
        
        # End of block
        $0 ~ end {
            # Output collected content
            printf "%s", block_content
            # Add our new/updated key
            if (value != "") {
                print key " " value
            }
            print $0
            in_block=0
            next
        }
        
        # Outside block
        !in_block { print }
    ' "$TORRC_PATH" > "$tmp_file"
    
    mv "$tmp_file" "$TORRC_PATH"
    restore_permissions "$original_perms"
    trap - EXIT
}

remove_config_value() {
    local key="$1"
    set_config_value "$key" ""
}

################################################################################
# Backup and Permissions Management
################################################################################

backup_torrc() {
    if [[ ! -f "$TORRC_PATH" ]]; then
        return
    fi
    
    local backup_dir
    backup_dir=$(dirname "$TORRC_PATH")
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$TORRC_PATH.backup.$timestamp"
    
    cp -p "$TORRC_PATH" "$backup_file"
    
    local backup_count
    backup_count=$(ls -1 "$TORRC_PATH.backup."* 2>/dev/null | wc -l)
    
    if [[ $backup_count -gt 5 ]]; then
        ls -1t "$TORRC_PATH.backup."* | tail -n+$((backup_count - 4)) | xargs -r rm
    fi
}

get_file_permissions() {
    stat -c %a "$TORRC_PATH" 2>/dev/null || stat -f %Lp "$TORRC_PATH" 2>/dev/null
}

restore_permissions() {
    local original_perms="$1"
    if [[ -n "$original_perms" ]]; then
        chmod "$original_perms" "$TORRC_PATH"
    fi
}

################################################################################
# Service Management
################################################################################

get_tor_status() {
    if systemctl is-active --quiet tor; then
        echo "active"
    else
        echo "inactive"
    fi
}

get_tor_external_ip() {
    local ip
    ip=$(timeout 5 curl -s --socks5 127.0.0.1:"$SOCKS_PORT" https://check.torproject.org/api/ip 2>/dev/null | grep -oP '"IsTor":\s*true.*?"IP":\s*"\K[^"]+' || echo "N/A")
    echo "$ip"
}

service_control_menu() {
    while true; do
        local status
        status=$(get_tor_status)
        local status_display
        if [[ "$status" == "active" ]]; then
            status_display="$(gum style --foreground 82 '●') Active"
        else
            status_display="$(gum style --foreground 196 '●') Inactive"
        fi
        
        gum style --border rounded --padding "1 2" --border-foreground 212 \
            "Service Control" \
            "" \
            "Current Status: $status_display"
        
        local choice
        choice=$(gum choose \
            "Start Service" \
            "Stop Service" \
            "Restart Service" \
            "Reload Configuration" \
            "Enable on Boot" \
            "Disable on Boot" \
            "Panic Stop (Force Kill)" \
            "← Back to Main Menu")
        
        case "$choice" in
            "Start Service")
                gum spin --spinner dot --title "Starting Tor..." -- systemctl start tor
                gum style --foreground 82 "✓ Tor started successfully!"
                sleep 1
                ;;
            "Stop Service")
                if gum confirm "Stop Tor service?"; then
                    gum spin --spinner dot --title "Stopping Tor..." -- systemctl stop tor
                    gum style --foreground 82 "✓ Tor stopped."
                    sleep 1
                fi
                ;;
            "Restart Service")
                gum spin --spinner dot --title "Restarting Tor..." -- systemctl restart tor
                gum style --foreground 82 "✓ Tor restarted successfully!"
                sleep 1
                ;;
            "Reload Configuration")
                gum spin --spinner dot --title "Reloading Tor configuration..." -- systemctl reload tor
                gum style --foreground 82 "✓ Configuration reloaded!"
                sleep 1
                ;;
            "Enable on Boot")
                gum spin --spinner dot --title "Enabling Tor on boot..." -- systemctl enable tor
                gum style --foreground 82 "✓ Tor will start automatically on boot."
                sleep 1
                ;;
            "Disable on Boot")
                gum spin --spinner dot --title "Disabling Tor on boot..." -- systemctl disable tor
                gum style --foreground 82 "✓ Tor will not start automatically on boot."
                sleep 1
                ;;
            "Panic Stop (Force Kill)")
                if gum confirm --affirmative="FORCE KILL" --negative="Cancel" "Force kill all Tor processes?"; then
                    pkill -9 tor || true
                    gum style --foreground 196 "✓ Tor processes terminated forcefully!"
                    sleep 1
                fi
                ;;
            "← Back to Main Menu")
                return
                ;;
        esac
    done
}

################################################################################
# Configuration Editor
################################################################################

config_editor_menu() {
    while true; do
        local current_socks
        local current_control
        local current_exit
        
        current_socks=$(get_config_value "SocksPort" "$SOCKS_PORT")
        current_control=$(get_config_value "ControlPort" "disabled")
        current_exit=$(get_config_value "ExitNodes" "any")
        
        gum style --border rounded --padding "1 2" --border-foreground 212 \
            "Configuration Editor" \
            "" \
            "Current Settings:" \
            "  SOCKS Port: $current_socks" \
            "  Control Port: $current_control" \
            "  Exit Nodes: $current_exit"
        
        local choice
        choice=$(gum choose \
            "Edit SOCKS Port" \
            "Toggle Control Port" \
            "Set Exit Nodes" \
            "View Full Config" \
            "← Back to Main Menu")
        
        case "$choice" in
            "Edit SOCKS Port")
                edit_socks_port
                ;;
            "Toggle Control Port")
                toggle_control_port
                ;;
            "Set Exit Nodes")
                edit_exit_nodes
                ;;
            "View Full Config")
                view_config
                ;;
            "← Back to Main Menu")
                return
                ;;
        esac
    done
}

edit_socks_port() {
    local current
    current=$(get_config_value "SocksPort" "$SOCKS_PORT")
    
    local new_port
    new_port=$(gum input --placeholder "$current" --prompt "SOCKS Port > " --value "$current")
    
    if [[ -n "$new_port" ]] && [[ "$new_port" =~ ^[0-9]+$ ]]; then
        set_config_value "SocksPort" "$new_port"
        gum style --foreground 82 "✓ SOCKS Port set to $new_port"
        gum style --foreground 226 "⚠ Restart Tor for changes to take effect."
        sleep 2
    else
        gum style --foreground 196 "Invalid port number."
        sleep 1
    fi
}

toggle_control_port() {
    local current
    current=$(get_config_value "ControlPort" "disabled")
    
    if [[ "$current" == "disabled" ]] || [[ -z "$current" ]]; then
        gum style --foreground 226 \
            "⚠ Enabling Control Port" \
            "" \
            "The Control Port ($CONTROL_PORT) is required for:" \
            "  • New Identity feature" \
            "  • Advanced Tor control" \
            "" \
            "Security note: Only localhost connections are allowed."
        
        if gum confirm "Enable Control Port?"; then
            set_config_value "ControlPort" "$CONTROL_PORT"
            gum style --foreground 82 "✓ Control Port enabled on $CONTROL_PORT"
            gum style --foreground 226 "⚠ Restart Tor for changes to take effect."
            sleep 2
        fi
    else
        if gum confirm "Disable Control Port? (This will break 'New Identity' feature)"; then
            remove_config_value "ControlPort"
            gum style --foreground 82 "✓ Control Port disabled."
            gum style --foreground 226 "⚠ Restart Tor for changes to take effect."
            sleep 2
        fi
    fi
}

edit_exit_nodes() {
    gum style --foreground 212 \
        "Exit Node Configuration" \
        "" \
        "Specify country codes (e.g., {us},{de},{gb})" \
        "Leave empty for any exit node."
    
    local current
    current=$(get_config_value "ExitNodes" "")
    
    local new_exit
    new_exit=$(gum input --placeholder "{us},{de},{gb}" --prompt "Exit Nodes > " --value "$current")
    
    if [[ -n "$new_exit" ]]; then
        set_config_value "ExitNodes" "$new_exit"
        gum style --foreground 82 "✓ Exit Nodes set to $new_exit"
    else
        remove_config_value "ExitNodes"
        gum style --foreground 82 "✓ Exit Nodes cleared (using any)."
    fi
    
    gum style --foreground 226 "⚠ Restart Tor for changes to take effect."
    sleep 2
}

view_config() {
    clear
    gum style --border double --padding "1 2" --border-foreground 212 "TorMan Managed Configuration"
    echo ""
    sed -n "/$CONFIG_BEGIN_MARKER/,/$CONFIG_END_MARKER/p" "$TORRC_PATH" | gum format
    echo ""
    gum style --foreground 226 "Press any key to continue..."
    read -n 1 -s
}

################################################################################
# Onion Service Management
################################################################################

onion_service_menu() {
    while true; do
        gum style --border rounded --padding "1 2" --border-foreground 212 \
            "Onion Service Manager"
        
        local choice
        choice=$(gum choose \
            "List Onion Services" \
            "Create New Service" \
            "Delete Service" \
            "← Back to Main Menu")
        
        case "$choice" in
            "List Onion Services")
                list_onion_services
                ;;
            "Create New Service")
                create_onion_service
                ;;
            "Delete Service")
                delete_onion_service
                ;;
            "← Back to Main Menu")
                return
                ;;
        esac
    done
}

list_onion_services() {
    clear
    gum style --border double --padding "1 2" --border-foreground 212 "Active Onion Services"
    echo ""
    
    local found=0
    
    # Parse torrc for HiddenServiceDir entries in our block
    while IFS= read -r line; do
        if [[ "$line" =~ ^HiddenServiceDir[[:space:]]+(.+)$ ]]; then
            local service_dir="${BASH_REMATCH[1]}"
            local service_name
            service_name=$(basename "$service_dir")
            local hostname_file="$service_dir/hostname"
            
            if [[ -f "$hostname_file" ]]; then
                local hostname
                hostname=$(cat "$hostname_file")
                gum style --foreground 212 "● $service_name"
                gum style --foreground 246 "  Directory: $service_dir"
                gum style --foreground 82 "  Hostname: $hostname"
                echo ""
                found=1
            fi
        fi
    done < <(sed -n "/$CONFIG_BEGIN_MARKER/,/$CONFIG_END_MARKER/p" "$TORRC_PATH")
    
    if [[ $found -eq 0 ]]; then
        gum style --foreground 226 "No onion services configured."
        echo ""
    fi
    
    gum style --foreground 246 "Press any key to continue..."
    read -n 1 -s
}

create_onion_service() {
    gum style --border rounded --padding "1 2" --border-foreground 212 \
        "Create New Onion Service"
    
    # Get service name
    local service_name
    service_name=$(gum input --placeholder "my-service" --prompt "Service Name > ")
    
    if [[ -z "$service_name" ]]; then
        gum style --foreground 196 "Service name cannot be empty."
        sleep 1
        return
    fi
    
    # Sanitize service name
    service_name=$(echo "$service_name" | tr -cd '[:alnum:]-_')
    
    # Get local port
    local local_port
    local_port=$(gum input --placeholder "80" --prompt "Local Port (service running on) > ")
    
    if [[ ! "$local_port" =~ ^[0-9]+$ ]]; then
        gum style --foreground 196 "Invalid port number."
        sleep 1
        return
    fi
    
    # Get Tor port
    local tor_port
    tor_port=$(gum input --placeholder "80" --prompt "Tor Port (external) > ")
    
    if [[ ! "$tor_port" =~ ^[0-9]+$ ]]; then
        gum style --foreground 196 "Invalid port number."
        sleep 1
        return
    fi
    
    local service_dir="$TOR_DATA_DIR/$service_name"
    
    # Check if directory already exists
    if [[ -d "$service_dir" ]]; then
        gum style --foreground 196 "Service directory already exists: $service_dir"
        sleep 2
        return
    fi
    
    gum spin --spinner dot --title "Creating onion service..." -- bash -c "
        # Create directory
        mkdir -p '$service_dir'
        chown "$TOR_USER:$TOR_USER" '$service_dir'
        chmod 700 '$service_dir'
    "
    
    # Add to torrc - we need to add it to our managed block
    backup_torrc
    local original_perms
    original_perms=$(get_file_permissions)
    
    local tmp_file
    tmp_file=$(mktemp)
    trap 'rm -f "$tmp_file"' EXIT
    
    awk -v end="$CONFIG_END_MARKER" \
        -v service_dir="$service_dir" \
        -v tor_port="$tor_port" \
        -v local_port="$local_port" '
        $0 ~ end {
            print "HiddenServiceDir " service_dir
            print "HiddenServicePort " tor_port " 127.0.0.1:" local_port
            print $0
            next
        }
        { print }
    ' "$TORRC_PATH" > "$tmp_file"
    
    mv "$tmp_file" "$TORRC_PATH"
    restore_permissions "$original_perms"
    trap - EXIT
    
    gum style --foreground 82 "✓ Service configuration added."
    
    # Reload Tor to generate hostname
    gum spin --spinner dot --title "Reloading Tor to generate hostname..." -- systemctl reload tor
    
    # Wait for hostname file
    local hostname_file="$service_dir/hostname"
    local wait_count=0
    while [[ ! -f "$hostname_file" ]] && [[ $wait_count -lt 10 ]]; do
        sleep 1
        ((wait_count++))
    done
    
    if [[ -f "$hostname_file" ]]; then
        local hostname
        hostname=$(cat "$hostname_file")
        
        clear
        gum style --border double --padding "1 2" --border-foreground 82 \
            "✓ Onion Service Created Successfully!" \
            "" \
            "Service Name: $service_name" \
            "Onion Address: $hostname" \
            "Port Mapping: $tor_port → 127.0.0.1:$local_port"
        
        # Generate QR code if qrencode is available
        if command -v qrencode &> /dev/null; then
            echo ""
            gum style --foreground 212 "QR Code:"
            qrencode -t ANSIUTF8 "$hostname"
        fi
        
        echo ""
        gum style --foreground 246 "Press any key to continue..."
        read -n 1 -s
    else
        gum style --foreground 196 "Failed to generate hostname. Check Tor logs."
        sleep 2
    fi
}

delete_onion_service() {
    # List available services
    local services=()
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^HiddenServiceDir[[:space:]]+(.+)$ ]]; then
            local service_dir="${BASH_REMATCH[1]}"
            local service_name
            service_name=$(basename "$service_dir")
            services+=("$service_name|$service_dir")
        fi
    done < <(sed -n "/$CONFIG_BEGIN_MARKER/,/$CONFIG_END_MARKER/p" "$TORRC_PATH")
    
    if [[ ${#services[@]} -eq 0 ]]; then
        gum style --foreground 226 "No onion services to delete."
        sleep 1
        return
    fi
    
    # Format for display
    local service_choices=()
    for svc in "${services[@]}"; do
        local name="${svc%%|*}"
        service_choices+=("$name")
    done
    service_choices+=("← Cancel")
    
    local choice
    choice=$(gum choose "${service_choices[@]}")
    
    if [[ "$choice" == "← Cancel" ]]; then
        return
    fi
    
    # Find the directory for this service
    local service_dir=""
    for svc in "${services[@]}"; do
        local name="${svc%%|*}"
        if [[ "$name" == "$choice" ]]; then
            service_dir="${svc##*|}"
            break
        fi
    done
    
    gum style --foreground 196 \
        "⚠ WARNING: This will permanently delete:" \
        "  • Configuration from torrc" \
        "  • Service directory: $service_dir" \
        "  • All keys and hostname"
    
    if gum confirm --affirmative="DELETE" --negative="Cancel" "Permanently delete '$choice'?"; then
        # Remove from torrc
        backup_torrc
        local original_perms
        original_perms=$(get_file_permissions)
        
        local tmp_file
        tmp_file=$(mktemp)
        trap 'rm -f "$tmp_file"' EXIT
        
        awk -v service_dir="$service_dir" '
            # Skip HiddenServiceDir line and the following HiddenServicePort line(s)
            $0 ~ "^HiddenServiceDir " service_dir {
                skip_next = 1
                next
            }
            skip_next && /^HiddenServicePort/ {
                next
            }
            {
                skip_next = 0
                print
            }
        ' "$TORRC_PATH" > "$tmp_file"
        
        mv "$tmp_file" "$TORRC_PATH"
        restore_permissions "$original_perms"
        trap - EXIT
        
        # Remove directory
        rm -rf "$service_dir"
        
        gum style --foreground 82 "✓ Service '$choice' deleted."
        gum spin --spinner dot --title "Reloading Tor..." -- systemctl reload tor
        sleep 1
    fi
}

################################################################################
# Identity Tools
################################################################################

identity_tools_menu() {
    while true; do
        gum style --border rounded --padding "1 2" --border-foreground 212 \
            "Identity & IP Tools"
        
        local choice
        choice=$(gum choose \
            "Get New Identity (NEWNYM)" \
            "Check Current IP" \
            "Check Tor Connectivity" \
            "← Back to Main Menu")
        
        case "$choice" in
            "Get New Identity (NEWNYM)")
                new_identity
                ;;
            "Check Current IP")
                check_ip
                ;;
            "Check Tor Connectivity")
                check_tor_connectivity
                ;;
            "← Back to Main Menu")
                return
                ;;
        esac
    done
}

new_identity() {
    local control_port
    control_port=$(get_config_value "ControlPort" "")
    
    if [[ -z "$control_port" ]] || [[ "$control_port" == "disabled" ]]; then
        gum style --foreground 196 \
            "✗ Control Port is disabled!" \
            "" \
            "Enable it in Configuration Editor first."
        sleep 2
        return
    fi
    
    gum spin --spinner dot --title "Requesting new identity..." -- bash -c "
        echo -e 'AUTHENTICATE \"\"\nSIGNAL NEWNYM\nQUIT' | nc 127.0.0.1 $control_port > /dev/null 2>&1
    "
    
    if [[ $? -eq 0 ]]; then
        gum style --foreground 82 "✓ New identity requested successfully!"
        gum style --foreground 226 "Note: Tor will use a new circuit. Wait a few seconds."
    else
        gum style --foreground 196 "✗ Failed to request new identity."
        gum style --foreground 226 "Ensure Control Port is enabled and Tor is running."
    fi
    
    sleep 2
}

check_ip() {
    gum spin --spinner dot --title "Checking IP address..." -- sleep 0.5
    
    local socks_port
    socks_port=$(get_config_value "SocksPort" "$SOCKS_PORT")
    
    local ip
    ip=$(timeout 10 curl -s --socks5 127.0.0.1:"$socks_port" https://check.torproject.org/api/ip 2>/dev/null)
    
    if [[ -n "$ip" ]]; then
        local is_tor
        is_tor=$(echo "$ip" | grep -o '"IsTor":\s*true' || echo "false")
        local ip_addr
        ip_addr=$(echo "$ip" | grep -oP '"IP":\s*"\K[^"]+' || echo "Unknown")
        
        clear
        if [[ "$is_tor" != "false" ]]; then
            gum style --border double --padding "1 2" --border-foreground 82 \
                "✓ Connected via Tor" \
                "" \
                "Your IP: $ip_addr" \
                "Status: Using Tor network"
        else
            gum style --border double --padding "1 2" --border-foreground 196 \
                "✗ NOT using Tor" \
                "" \
                "Your IP: $ip_addr" \
                "Status: Direct connection"
        fi
    else
        gum style --foreground 196 "✗ Failed to check IP. Is Tor running?"
    fi
    
    echo ""
    gum style --foreground 246 "Press any key to continue..."
    read -n 1 -s
}

check_tor_connectivity() {
    gum spin --spinner dot --title "Testing Tor connectivity..." -- sleep 0.5
    
    local socks_port
    socks_port=$(get_config_value "SocksPort" "$SOCKS_PORT")
    
    local result
    result=$(timeout 10 curl -s --socks5 127.0.0.1:"$socks_port" https://check.torproject.org/ 2>/dev/null)
    
    if echo "$result" | grep -q "Congratulations"; then
        gum style --foreground 82 "✓ Tor is working correctly!"
    else
        gum style --foreground 196 "✗ Cannot connect through Tor."
        gum style --foreground 226 "Check if Tor is running and SOCKS port is correct."
    fi
    
    sleep 2
}

################################################################################
# Logs Viewer
################################################################################

view_logs() {
    clear
    gum style --border double --padding "1 2" --border-foreground 212 "Tor Service Logs (last 50 lines)"
    echo ""
    
    journalctl -u tor -n 50 --no-pager | gum format
    
    echo ""
    gum style --foreground 246 "Press any key to continue..."
    read -n 1 -s
}

################################################################################
# Main Dashboard
################################################################################

show_header() {
    clear
    local status
    status=$(get_tor_status)
    
    local status_icon
    local status_color
    if [[ "$status" == "active" ]]; then
        status_icon="●"
        status_color=82
    else
        status_icon="●"
        status_color=196
    fi
    
    local ip="Checking..."
    if [[ "$status" == "active" ]]; then
        ip=$(get_tor_external_ip)
    fi
    
    gum style \
        --border double \
        --border-foreground 212 \
        --padding "1 4" \
        --margin "1 0" \
        --align center \
        "$(gum style --foreground 212 --bold 'TorMan')" \
        "$(gum style --foreground 246 'Advanced Tor Management System')" \
        "" \
        "$(gum style --foreground $status_color "$status_icon") Status: $(gum style --bold "$status")" \
        "$(gum style --foreground 82 '🌐') Exit IP: $(gum style --bold "$ip")" \
        "" \
        "$(gum style --foreground 246 --italic "v$SCRIPT_VERSION")"
}

main_menu() {
    while true; do
        show_header
        
        local choice
        choice=$(gum choose \
            --height 12 \
            --cursor "→ " \
            "⚙️  Service Control" \
            "📝 Configuration Editor" \
            "🔄 Identity Tools" \
            "🧅 Onion Services" \
            "📋 View Logs" \
            "❌ Exit")
        
        case "$choice" in
            "⚙️  Service Control")
                service_control_menu
                ;;
            "📝 Configuration Editor")
                config_editor_menu
                ;;
            "🔄 Identity Tools")
                identity_tools_menu
                ;;
            "🧅 Onion Services")
                onion_service_menu
                ;;
            "📋 View Logs")
                view_logs
                ;;
            "❌ Exit")
                clear
                gum style --foreground 212 "Thanks for using TorMan!"
                exit 0
                ;;
        esac
    done
}

################################################################################
# Entry Point
################################################################################

main() {
    # Pre-flight checks
    check_root
    check_gum
    check_dependencies
    check_torrc
    
    # Ensure our config block exists
    ensure_config_block
    
    # Launch main menu
    main_menu
}

# Run the script
main "$@"
