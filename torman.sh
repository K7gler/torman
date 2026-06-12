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
readonly BACKUP_DIR="/var/backups/torman"

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
    
    for cmd in tor curl nc gzip; do
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
        [gzip]="gzip"
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
    
    if ! validate_tor_config; then
        return
    fi
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
# Tor Config Validation
################################################################################

validate_tor_config() {
    local verify_output
    local verify_exit
    
    gum spin --spinner dot --title "Validating Tor configuration..." -- \
        verify_output=$(tor -f "$TORRC_PATH" --verify-config 2>&1)
    verify_exit=$?
    
    if [[ $verify_exit -ne 0 ]]; then
        clear
        gum style --border rounded --padding "1 2" --border-foreground 196 \
            "✗ Tor Configuration Validation Failed" \
            "" \
            "Error output:" \
            "" \
            "$(echo "$verify_output" | head -20 | gum format)"
        
        local latest_backup
        latest_backup=$(ls -t "$TORRC_PATH.backup."* 2>/dev/null | head -n1)
        
        if [[ -n "$latest_backup" ]] && gum confirm "Restore from latest backup?"; then
            cp -p "$latest_backup" "$TORRC_PATH"
            gum style --foreground 82 "✓ Restored from $latest_backup"
            sleep 2
            return 1
        fi
        
        gum style --foreground 196 "Configuration NOT applied. Please fix errors manually."
        sleep 3
        return 1
    fi
    
    return 0
}

restore_from_backup() {
    local latest_backup
    latest_backup=$(ls -t "$TORRC_PATH.backup."* 2>/dev/null | head -n1)
    
    if [[ -n "$latest_backup" ]]; then
        cp -p "$latest_backup" "$TORRC_PATH"
        gum style --foreground 82 "✓ Restored from $latest_backup"
    else
        gum style --foreground 196 "No backup found."
    fi
}

is_port_available() {
    local port="$1"
    
    if command -v ss &> /dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":$port "; then
            return 1
        fi
    elif command -v netstat &> /dev/null; then
        if netstat -tlnp 2>/dev/null | grep -q ":$port "; then
            return 1
        fi
    fi
    
    return 0
}

is_port_listening() {
    local port="$1"
    
    if command -v ss &> /dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":$port "; then
            return 0
        fi
    elif command -v netstat &> /dev/null; then
        if netstat -tlnp 2>/dev/null | grep -q ":$port "; then
            return 0
        fi
    fi
    
    return 1
}

validate_port() {
    local port="$1"
    local port_name="${2:-Port}"
    
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]; then
        gum style --foreground 196 "✗ $port_name must be between 1 and 65535."
        return 1
    fi
    
    if [[ $port -lt 1024 ]]; then
        gum style --foreground 226 "⚠ Warning: $port_name $port is a privileged port (< 1024). Root binding required."
        if ! gum confirm "Continue anyway?"; then
            return 1
        fi
    fi
    
    if is_port_available "$port"; then
        gum style --foreground 226 "⚠ Warning: Port $port may already be in use."
        if ! gum confirm "Continue anyway?"; then
            return 1
        fi
    fi
    
    return 0
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

offer_restart() {
    local status
    status=$(get_tor_status)
    
    if [[ "$status" == "active" ]]; then
        if gum confirm "Restart Tor now to apply changes?"; then
            gum spin --spinner dot --title "Restarting Tor..." -- systemctl restart tor
            gum style --foreground 82 "✓ Tor restarted successfully!"
            sleep 1
        fi
    else
        if gum confirm "Start Tor now to apply changes?"; then
            gum spin --spinner dot --title "Starting Tor..." -- systemctl start tor
            gum style --foreground 82 "✓ Tor started successfully!"
            sleep 1
        fi
    fi
}

get_tor_external_ip() {
    local ip
    ip=$(timeout 5 curl -s --socks5 127.0.0.1:"$SOCKS_PORT" https://check.torproject.org/api/ip 2>/dev/null | awk -F'"IP": *"' '{if($2)print substr($2,2,index($2,"\"}")-1)}')
    echo "${ip:-N/A}"
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
        local current_exclude
        local current_exclude_exit
        local current_strict
        
        current_socks=$(get_config_value "SocksPort" "$SOCKS_PORT")
        current_control=$(get_config_value "ControlPort" "disabled")
        current_exit=$(get_config_value "ExitNodes" "any")
        current_exclude=$(get_config_value "ExcludeNodes" "none")
        current_exclude_exit=$(get_config_value "ExcludeExitNodes" "none")
        current_strict=$(get_config_value "StrictNodes" "0")
        
        gum style --border rounded --padding "1 2" --border-foreground 212 \
            "Configuration Editor" \
            "" \
            "Current Settings:" \
            "  SOCKS Port: $current_socks" \
            "  Control Port: $current_control" \
            "  Exit Nodes: $current_exit" \
            "  Exclude Nodes: $current_exclude" \
            "  Exclude Exit Nodes: $current_exclude_exit" \
            "  StrictNodes: $current_strict"
        
        local choice
        choice=$(gum choose \
            "Edit SOCKS Port" \
            "Toggle Control Port" \
            "Toggle StrictNodes" \
            "Set Exit Nodes" \
            "Set Exclude Nodes" \
            "Set Exclude Exit Nodes" \
            "View Full Config" \
            "Export Config" \
            "Import Config" \
            "← Back to Main Menu")
        
        case "$choice" in
            "Edit SOCKS Port")
                edit_socks_port
                ;;
            "Toggle Control Port")
                toggle_control_port
                ;;
            "Toggle StrictNodes")
                toggle_strict_nodes
                ;;
            "Set Exit Nodes")
                edit_exit_nodes
                ;;
            "Set Exclude Nodes")
                edit_exclude_nodes
                ;;
            "Set Exclude Exit Nodes")
                edit_exclude_exit_nodes
                ;;
            "View Full Config")
                view_config
                ;;
            "Export Config")
                export_config
                ;;
            "Import Config")
                import_config
                ;;
            "← Back to Main Menu")
                return
                ;;
        esac
    done
}

toggle_strict_nodes() {
    gum style --foreground 226 \
        "⚠ StrictNodes Warning" \
        "" \
        "StrictNodes forces Tor to ONLY use your specified ExitNodes." \
        "If none are available, Tor will fail to connect."
    
    local current
    current=$(get_config_value "StrictNodes" "0")
    
    if [[ "$current" == "1" ]]; then
        if gum confirm "StrictNodes is ENABLED. Disable it?"; then
            set_config_value "StrictNodes" "0"
            gum style --foreground 82 "✓ StrictNodes disabled."
            offer_restart
        fi
    else
        if gum confirm "Enable StrictNodes?"; then
            set_config_value "StrictNodes" "1"
            gum style --foreground 82 "✓ StrictNodes enabled."
            offer_restart
        fi
    fi
}

edit_socks_port() {
    local current
    current=$(get_config_value "SocksPort" "$SOCKS_PORT")
    
    local new_port
    new_port=$(gum input --placeholder "$current" --prompt "SOCKS Port > " --value "$current")
    
    if [[ -n "$new_port" ]]; then
        if ! validate_port "$new_port" "SOCKS Port"; then
            sleep 1
            return
        fi
        
        set_config_value "SocksPort" "$new_port"
        gum style --foreground 82 "✓ SOCKS Port set to $new_port"
        offer_restart
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
            offer_restart
        fi
    else
        if gum confirm "Disable Control Port? (This will break 'New Identity' feature)"; then
            remove_config_value "ControlPort"
            gum style --foreground 82 "✓ Control Port disabled."
            offer_restart
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
        local invalid=0
        local codes=$(echo "$new_exit" | grep -oE '\{[a-zA-Z]{2}\}' | tr -d '{}')
        local code_count=$(echo "$codes" | grep -c '[a-zA-Z][a-zA-Z]' || true)
        local expected_count=$(echo "$new_exit" | grep -c '{' || true)
        
        if [[ $code_count -ne $expected_count ]]; then
            gum style --foreground 196 "✗ Invalid country code format!" \
                "" \
                "Each country code must be 2 letters inside braces: {us}, {de}, {gb}" \
                "Example: {us},{de},{gb}"
            sleep 3
            return
        fi
        
        set_config_value "ExitNodes" "$new_exit"
        gum style --foreground 82 "✓ Exit Nodes set to $new_exit"
        offer_restart
    else
        remove_config_value "ExitNodes"
        gum style --foreground 82 "✓ Exit Nodes cleared (using any)."
        offer_restart
    fi
}

edit_exclude_nodes() {
    gum style --foreground 212 \
        "Exclude Nodes Configuration" \
        "" \
        "Exclude country codes (e.g., {ru},{cn})" \
        "These countries will NEVER be used in circuits." \
        "Leave empty for no exclusions."
    
    local current
    current=$(get_config_value "ExcludeNodes" "")
    
    local new_exclude
    new_exclude=$(gum input --placeholder "{ru},{cn}" --prompt "Exclude Nodes > " --value "$current")
    
    if [[ -n "$new_exclude" ]]; then
        local codes=$(echo "$new_exclude" | grep -oE '\{[a-zA-Z]{2}\}' | tr -d '{}')
        local code_count=$(echo "$codes" | grep -c '[a-zA-Z][a-zA-Z]' || true)
        local expected_count=$(echo "$new_exclude" | grep -c '{' || true)
        
        if [[ $code_count -ne $expected_count ]]; then
            gum style --foreground 196 "✗ Invalid country code format!" \
                "" \
                "Each country code must be 2 letters inside braces: {ru}, {cn}, {kp}" \
                "Example: {ru},{cn}"
            sleep 3
            return
        fi
        
        set_config_value "ExcludeNodes" "$new_exclude"
        gum style --foreground 82 "✓ Exclude Nodes set to $new_exclude"
        offer_restart
    else
        remove_config_value "ExcludeNodes"
        gum style --foreground 82 "✓ Exclude Nodes cleared."
        offer_restart
    fi
}

edit_exclude_exit_nodes() {
    gum style --foreground 212 \
        "Exclude Exit Nodes Configuration" \
        "" \
        "Exclude exit node countries (e.g., {ru},{cn})" \
        "These countries will NEVER be used as exits." \
        "Leave empty for no exclusions."
    
    local current
    current=$(get_config_value "ExcludeExitNodes" "")
    
    local new_exclude
    new_exclude=$(gum input --placeholder "{ru},{cn}" --prompt "Exclude Exit Nodes > " --value "$current")
    
    if [[ -n "$new_exclude" ]]; then
        local codes=$(echo "$new_exclude" | grep -oE '\{[a-zA-Z]{2}\}' | tr -d '{}')
        local code_count=$(echo "$codes" | grep -c '[a-zA-Z][a-zA-Z]' || true)
        local expected_count=$(echo "$new_exclude" | grep -c '{' || true)
        
        if [[ $code_count -ne $expected_count ]]; then
            gum style --foreground 196 "✗ Invalid country code format!" \
                "" \
                "Each country code must be 2 letters inside braces: {ru}, {cn}, {kp}" \
                "Example: {ru},{cn}"
            sleep 3
            return
        fi
        
        set_config_value "ExcludeExitNodes" "$new_exclude"
        gum style --foreground 82 "✓ Exclude Exit Nodes set to $new_exclude"
        offer_restart
    else
        remove_config_value "ExcludeExitNodes"
        gum style --foreground 82 "✓ Exclude Exit Nodes cleared."
        offer_restart
    fi
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

export_config() {
    local default_path
    default_path="$HOME/torman-config-export-$(date +%Y%m%d-%H%M%S).txt"
    
    local export_path
    export_path=$(gum input --placeholder "$default_path" --prompt "Export path > " --value "$default_path")
    
    if [[ -z "$export_path" ]]; then
        gum style --foreground 196 "Export path cannot be empty."
        sleep 1
        return
    fi
    
    local config_block
    config_block=$(sed -n "/$CONFIG_BEGIN_MARKER/,/$CONFIG_END_MARKER/p" "$TORRC_PATH")
    
    if [[ -z "$config_block" ]]; then
        gum style --foreground 196 "No configuration block found to export."
        sleep 1
        return
    fi
    
    local hostname
    hostname=$(hostname 2>/dev/null || echo "unknown")
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    
    if ! mkdir -p "$(dirname "$export_path")" 2>/dev/null; then
        gum style --foreground 196 "Failed to create directory for export path."
        sleep 1
        return
    fi
    
    if printf '# TorMan Configuration Export\n# Generated: %s\n# Machine: %s\n#\n%s\n' "$timestamp" "$hostname" "$config_block" > "$export_path"; then
        chmod 600 "$export_path"
        gum style --foreground 82 "✓ Configuration exported to $export_path"
    else
        gum style --foreground 196 "Failed to write export file."
    fi
    
    sleep 1
}

import_config() {
    local import_path
    import_path=$(gum input --placeholder "/path/to/config.txt" --prompt "Import file path > ")
    
    if [[ -z "$import_path" ]]; then
        gum style --foreground 196 "Import path cannot be empty."
        sleep 1
        return
    fi
    
    if [[ ! -f "$import_path" ]]; then
        gum style --foreground 196 "File not found: $import_path"
        sleep 1
        return
    fi
    
    if ! grep -q "$CONFIG_BEGIN_MARKER" "$import_path"; then
        gum style --foreground 196 "File does not contain $CONFIG_BEGIN_MARKER"
        sleep 1
        return
    fi
    
    if ! grep -q "$CONFIG_END_MARKER" "$import_path"; then
        gum style --foreground 196 "File does not contain $CONFIG_END_MARKER"
        sleep 1
        return
    fi
    
    local import_block
    import_block=$(sed -n "/$CONFIG_BEGIN_MARKER/,/$CONFIG_END_MARKER/p" "$import_path")
    
    clear
    gum style --border double --padding "1 2" --border-foreground 212 "Import Preview"
    echo ""
    gum style --foreground 212 "Key-value pairs in import file:"
    echo ""
    
    echo "$import_block" | grep -E '^\w+\s+' | gum format
    echo ""
    
    gum style --foreground 196 \
        "⚠ WARNING: DESTRUCTIVE OPERATION" \
        "" \
        "Importing will OVERWRITE your existing managed configuration block." \
        "If onion services exist in the current config but not in the import," \
        "they will be LOST from torrc (though directories remain)."
    
    if ! gum confirm "Proceed with import?"; then
        gum style --foreground 226 "Import cancelled."
        sleep 1
        return
    fi
    
    backup_torrc
    local original_perms
    original_perms=$(get_file_permissions)
    
    local tmp_file
    tmp_file=$(mktemp)
    trap 'rm -f "$tmp_file"' EXIT
    
    awk -v begin="$CONFIG_BEGIN_MARKER" \
        -v end="$CONFIG_END_MARKER" \
        -v newblock="$import_block" '
    BEGIN { in_block=0 }
    
    $0 ~ begin {
        print $0
        in_block=1
        next
    }
    
    in_block && $0 !~ end {
        next
    }
    
    $0 ~ end {
        printf "%s", newblock
        print $0
        in_block=0
        next
    }
    
    !in_block { print }
    ' "$TORRC_PATH" > "$tmp_file"
    
    mv "$tmp_file" "$TORRC_PATH"
    restore_permissions "$original_perms"
    trap - EXIT
    
    if ! validate_tor_config; then
        return
    fi
    
    gum style --foreground 82 "✓ Configuration imported successfully!"
    offer_restart
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
            "Add Port to Existing Service" \
            "Delete Service" \
            "---" \
            "Backup Single Service" \
            "Backup All Services" \
            "Restore Service from Backup" \
            "← Back to Main Menu")
        
        case "$choice" in
            "List Onion Services")
                list_onion_services
                ;;
            "Create New Service")
                create_onion_service
                ;;
            "Add Port to Existing Service")
                add_onion_service_port
                ;;
            "Delete Service")
                delete_onion_service
                ;;
            "Backup Single Service")
                backup_single_service
                ;;
            "Backup All Services")
                backup_all_services
                ;;
            "Restore Service from Backup")
                restore_service
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
    
    local current_service=""
    local current_dir=""
    declare -A service_dirs
    declare -A port_mappings
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^HiddenServiceDir[[:space:]]+(.+)$ ]]; then
            if [[ -n "$current_service" ]] && [[ -n "$current_dir" ]]; then
                service_dirs["$current_service"]="$current_dir"
            fi
            current_dir="${BASH_REMATCH[1]}"
            current_service=$(basename "$current_dir")
            found=1
        elif [[ "$line" =~ ^HiddenServicePort[[:space:]]+([0-9]+)[[:space:]]+127\.0\.0\.1:([0-9]+)$ ]] && [[ -n "$current_service" ]]; then
            local tor_port="${BASH_REMATCH[1]}"
            local local_port="${BASH_REMATCH[2]}"
            if [[ -z "${port_mappings["$current_service"]:-}" ]]; then
                port_mappings["$current_service"]="$tor_port → 127.0.0.1:$local_port"
            else
                port_mappings["$current_service"]+=$'\n'"  + $tor_port → 127.0.0.1:$local_port"
            fi
        fi
    done < <(sed -n "/$CONFIG_BEGIN_MARKER/,/$CONFIG_END_MARKER/p" "$TORRC_PATH")
    
    if [[ -n "$current_service" ]] && [[ -n "$current_dir" ]]; then
        service_dirs["$current_service"]="$current_dir"
    fi
    
    for svc in "${!service_dirs[@]}"; do
        local service_dir="${service_dirs[$svc]}"
        local hostname_file="$service_dir/hostname"
        local hostname="Not yet generated"
        
        if [[ -f "$hostname_file" ]]; then
            hostname=$(cat "$hostname_file")
        fi
        
        gum style --foreground 212 "● $svc"
        gum style --foreground 246 "  Directory: $service_dir"
        gum style --foreground 82 "  Hostname: $hostname"
        
        local ports="${port_mappings[$svc]:-No ports configured}"
        gum style --foreground 213 "  Ports: $ports"
        echo ""
        found=1
    done
    
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
    
    declare -a tor_ports=()
    declare -a local_ports=()
    
    while true; do
        local lport
        lport=$(gum input --placeholder "80" --prompt "Local Port (service running on) > ")
        
        if [[ ! "$lport" =~ ^[0-9]+$ ]]; then
            gum style --foreground 196 "Invalid port number."
            sleep 1
            return
        fi
        
        if ! validate_port "$lport" "Local Port"; then
            sleep 1
            return
        fi
        
        if ! is_port_listening "$lport"; then
            gum style --foreground 226 "⚠ Warning: Nothing appears to be listening on port $lport."
            if ! gum confirm "Continue anyway?"; then
                return
            fi
        fi
        
        local tport
        tport=$(gum input --placeholder "80" --prompt "Tor Port (external) > ")
        
        if [[ ! "$tport" =~ ^[0-9]+$ ]]; then
            gum style --foreground 196 "Invalid port number."
            sleep 1
            return
        fi
        
        if ! validate_port "$tport" "Tor Port"; then
            sleep 1
            return
        fi
        
        tor_ports+=("$tport")
        local_ports+=("$lport")
        
        if ! gum confirm "Add another port mapping?"; then
            break
        fi
    done
    
    if [[ ${#tor_ports[@]} -eq 0 ]]; then
        gum style --foreground 196 "At least one port mapping is required."
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
    
    {
        awk -v end="$CONFIG_END_MARKER" \
            -v service_dir="$service_dir" '
        $0 ~ end {
            print "HiddenServiceDir " service_dir
            print $0
            next
        }
        { print }
        ' "$TORRC_PATH"
    } > "$tmp_file"
    
    local ports_line=""
    for i in "${!tor_ports[@]}"; do
        echo "HiddenServicePort ${tor_ports[$i]} 127.0.0.1:${local_ports[$i]}" >> "$tmp_file"
    done
    
    mv "$tmp_file" "$TORRC_PATH"
    restore_permissions "$original_perms"
    trap - EXIT
    
    if ! validate_tor_config; then
        return
    fi
    
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
            "Onion Address: $hostname"
        
        gum style --foreground 212 "Port Mappings:"
        for i in "${!tor_ports[@]}"; do
            gum style --foreground 213 "  ${tor_ports[$i]} → 127.0.0.1:${local_ports[$i]}"
        done
        
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
        /^HiddenServiceDir / && $2 == service_dir {
            skip_block = 1
            next
        }
        skip_block && /^HiddenServicePort / {
            next
        }
        skip_block && !/^HiddenServicePort / {
            skip_block = 0
        }
        /^HiddenServiceDir / {
            skip_block = 0
        }
        { print }
        ' "$TORRC_PATH" > "$tmp_file"
        
        mv "$tmp_file" "$TORRC_PATH"
        restore_permissions "$original_perms"
        
        if ! validate_tor_config; then
            trap - EXIT
            return
        fi
        trap - EXIT
        
        # Remove directory
        rm -rf "$service_dir"
        
        gum style --foreground 82 "✓ Service '$choice' deleted."
        gum spin --spinner dot --title "Reloading Tor..." -- systemctl reload tor
        sleep 1
    fi
}

add_onion_service_port() {
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
        gum style --foreground 226 "No onion services found."
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
    
    gum style --border rounded --padding "1 2" --border-foreground 212 \
        "Add Port to: $choice"
    
    # Get local port
    local local_port
    local_port=$(gum input --placeholder "80" --prompt "Local Port (service running on) > ")
    
    if [[ ! "$local_port" =~ ^[0-9]+$ ]]; then
        gum style --foreground 196 "Invalid port number."
        sleep 1
        return
    fi
    
    if ! validate_port "$local_port" "Local Port"; then
        sleep 1
        return
    fi
    
    if ! is_port_listening "$local_port"; then
        gum style --foreground 226 "⚠ Warning: Nothing appears to be listening on port $local_port."
        if ! gum confirm "Continue anyway?"; then
            return
        fi
    fi
    
    # Get Tor port
    local tor_port
    tor_port=$(gum input --placeholder "80" --prompt "Tor Port (external) > ")
    
    if [[ ! "$tor_port" =~ ^[0-9]+$ ]]; then
        gum style --foreground 196 "Invalid port number."
        sleep 1
        return
    fi
    
    if ! validate_port "$tor_port" "Tor Port"; then
        sleep 1
        return
    fi
    
    # Add the new HiddenServicePort line after the service's HiddenServiceDir
    backup_torrc
    local original_perms
    original_perms=$(get_file_permissions)
    
    local tmp_file
    tmp_file=$(mktemp)
    trap 'rm -f "$tmp_file"' EXIT
    
    awk -v service_dir="$service_dir" \
        -v tor_port="$tor_port" \
        -v local_port="$local_port" '
    /^HiddenServiceDir / && $2 == service_dir {
        print $0
        print "HiddenServicePort " tor_port " 127.0.0.1:" local_port
        next
    }
    { print }
    ' "$TORRC_PATH" > "$tmp_file"
    
    mv "$tmp_file" "$TORRC_PATH"
    restore_permissions "$original_perms"
    trap - EXIT
    
    if ! validate_tor_config; then
        return
    fi
    
    gum style --foreground 82 "✓ Port mapping added: $tor_port → 127.0.0.1:$local_port"
    
    if gum confirm "Reload Tor to apply changes?"; then
        gum spin --spinner dot --title "Reloading Tor..." -- systemctl reload tor
        gum style --foreground 82 "✓ Tor reloaded."
        sleep 1
    fi
}

################################################################################
# Onion Service Backup and Restore
################################################################################

backup_single_service() {
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
        gum style --foreground 226 "No onion services to backup."
        sleep 1
        return
    fi
    
    local service_choices=()
    for svc in "${services[@]}"; do
        local name="${svc%%|*}"
        service_choices+=("$name")
    done
    service_choices+=("← Cancel")
    
    local choice
    choice=$(gum choose "Select service to backup:" "${service_choices[@]}")
    
    if [[ "$choice" == "← Cancel" ]]; then
        return
    fi
    
    local service_dir=""
    for svc in "${services[@]}"; do
        local name="${svc%%|*}"
        if [[ "$name" == "$choice" ]]; then
            service_dir="${svc##*|}"
            break
        fi
    done
    
    mkdir -p "$BACKUP_DIR" 2>/dev/null || {
        gum style --foreground 196 "Failed to create backup directory: $BACKUP_DIR"
        sleep 2
        return
    }
    
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$BACKUP_DIR/${choice}-${timestamp}.tar.gz"
    
    if tar -czf "$backup_file" -C "$(dirname "$service_dir")" "$(basename "$service_dir")" 2>/dev/null; then
        chmod 600 "$backup_file"
        gum style --foreground 82 "✓ Backed up '$choice' to $backup_file"
    else
        gum style --foreground 196 "Failed to create backup for '$choice'"
        sleep 2
        return
    fi
    
    sleep 1
}

backup_all_services() {
    local services=()
    local service_dirs=()
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^HiddenServiceDir[[:space:]]+(.+)$ ]]; then
            local service_dir="${BASH_REMATCH[1]}"
            local service_name
            service_name=$(basename "$service_dir")
            services+=("$service_name")
            service_dirs+=("$service_dir")
        fi
    done < <(sed -n "/$CONFIG_BEGIN_MARKER/,/$CONFIG_END_MARKER/p" "$TORRC_PATH")
    
    if [[ ${#services[@]} -eq 0 ]]; then
        gum style --foreground 226 "No onion services to backup."
        sleep 1
        return
    fi
    
    mkdir -p "$BACKUP_DIR" 2>/dev/null || {
        gum style --foreground 196 "Failed to create backup directory: $BACKUP_DIR"
        sleep 2
        return
    }
    
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$BACKUP_DIR/onion-services-${timestamp}.tar.gz"
    
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN EXIT
    
    for svc_dir in "${service_dirs[@]}"; do
        ln -s "$svc_dir" "$tmp_dir/$(basename "$svc_dir")" 2>/dev/null || true
    done
    
    local tar_sources=""
    for svc in "${services[@]}"; do
        tar_sources="$tar_sources $(basename "$svc")"
    done
    
    if tar -czf "$backup_file" -C "$tmp_dir" $tar_sources 2>/dev/null; then
        chmod 600 "$backup_file"
        gum style --foreground 82 "✓ Backed up ${#services[@]} services to $backup_file"
    else
        rm -f "$backup_file"
        gum style --foreground 196 "Failed to create backup archive"
        sleep 2
        return
    fi
    
    sleep 1
}

restore_service() {
    if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -A "$BACKUP_DIR"/*.tar.gz 2>/dev/null)" ]]; then
        gum style --foreground 226 "No backups found in $BACKUP_DIR"
        sleep 1
        return
    fi
    
    local backups=()
    while IFS= read -r f; do
        backups+=("$(basename "$f")")
    done < <(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null)
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        gum style --foreground 226 "No backups found"
        sleep 1
        return
    fi
    
    local choice
    choice=$(gum choose "Select backup to restore:" "${backups[@]}" "← Cancel")
    
    if [[ "$choice" == "← Cancel" ]] || [[ -z "$choice" ]]; then
        return
    fi
    
    local backup_file="$BACKUP_DIR/$choice"
    local preview_lines
    preview_lines=$(tar -tzf "$backup_file" 2>/dev/null | head -20)
    
    clear
    gum style --border double --padding "1 2" --border-foreground 212 "Backup Contents: $choice"
    echo ""
    gum style --foreground 212 "Files in backup:"
    echo "$preview_lines" | gum format
    echo ""
    gum style --foreground 226 "⚠ WARNING: This will overwrite existing service directories!"
    
    if ! gum confirm "Restore from this backup?"; then
        return
    fi
    
    local services_in_backup=()
    while IFS= read -r line; do
        local svc_name=$(basename "$line" | tr -d '/')
        if [[ -n "$svc_name" ]] && [[ ! " ${services_in_backup[*]} " =~ " ${svc_name} " ]]; then
            services_in_backup+=("$svc_name")
        fi
    done < <(tar -tzf "$backup_file" 2>/dev/null | grep '/$' | head -20)
    
    for svc_name in "${services_in_backup[@]}"; do
        local target_dir="$TOR_DATA_DIR/$svc_name"
        
        if [[ -d "$target_dir" ]]; then
            gum style --foreground 226 "⚠ Service '$svc_name' already exists at $target_dir"
            if ! gum confirm "Overwrite existing '$svc_name'?"; then
                continue
            fi
        fi
        
        local extract_dir
        extract_dir=$(mktemp -d)
        trap 'rm -rf "$extract_dir"' RETURN EXIT
        
        if ! tar -xzf "$backup_file" -C "$extract_dir" 2>/dev/null; then
            gum style --foreground 196 "Failed to extract '$svc_name' from backup"
            sleep 2
            continue
        fi
        
        local extracted_path="$extract_dir/$svc_name"
        if [[ -d "$extracted_path" ]]; then
            mkdir -p "$target_dir"
            cp -r "$extracted_path"/* "$target_dir/" 2>/dev/null || true
            chown -R "$TOR_USER:$TOR_USER" "$target_dir"
            chmod 700 "$target_dir"
            
            if [[ ! -d "$target_dir" ]] || [[ -z "$(ls -A "$target_dir" 2>/dev/null)" ]]; then
                gum style --foreground 196 "Warning: $target_dir appears empty after restore"
            fi
        fi
        
        local torrc_has_entry=$(sed -n "/$CONFIG_BEGIN_MARKER/,/$CONFIG_END_MARKER/p" "$TORRC_PATH" | grep -c "^HiddenServiceDir $target_dir" || true)
        if [[ "$torrc_has_entry" -eq 0 ]]; then
            backup_torrc
            local original_perms
            original_perms=$(get_file_permissions)
            
            local tmp_file
            tmp_file=$(mktemp)
            trap 'rm -f "$tmp_file"' RETURN EXIT
            
            awk -v end="$CONFIG_END_MARKER" \
                -v service_dir="$target_dir" '
            $0 ~ end {
                print "HiddenServiceDir " service_dir
                print $0
                next
            }
            { print }
            ' "$TORRC_PATH" > "$tmp_file"
            
            mv "$tmp_file" "$TORRC_PATH"
            restore_permissions "$original_perms"
            trap - RETURN EXIT
        fi
        
        gum style --foreground 82 "✓ Restored service: $svc_name"
    done
    
    if validate_tor_config; then
        gum style --foreground 82 "✓ Configuration validated"
        offer_restart
    fi
    
    sleep 1
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
            "Show Circuit Info" \
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
            "Show Circuit Info")
                show_circuit_info
                ;;
            "← Back to Main Menu")
                return
                ;;
        esac
    done
}

authenticate_control_port() {
    local control_port="$1"
    shift
    local commands=("$@")
    
    local result_file=$(mktemp)
    local exit_file=$(mktemp)
    trap 'rm -f "$result_file" "$exit_file"' RETURN EXIT
    
    # Try empty auth first
    local auth_cmd="AUTHENTICATE \"\""
    for cmd in "${commands[@]}"; do
        auth_cmd="${auth_cmd}\n${cmd}"
    done
    auth_cmd="${auth_cmd}\nQUIT"
    
    echo -e "$auth_cmd" | nc 127.0.0.1 "$control_port" > "$result_file" 2>&1
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]] && grep -q "^250 OK" "$result_file"; then
        cat "$result_file"
        return 0
    fi
    
    # Fallback to cookie auth
    local cookie_file="/var/lib/tor/control_auth_cookie"
    if [[ -f "$cookie_file" ]]; then
        local cookie_hex
        cookie_hex=$(xxd -p "$cookie_file" | tr -d '\n')
        if [[ -n "$cookie_hex" ]]; then
            local cookie_cmd="AUTHENTICATE $cookie_hex"
            for cmd in "${commands[@]}"; do
                cookie_cmd="${cookie_cmd}\n${cmd}"
            done
            cookie_cmd="${cookie_cmd}\nQUIT"
            
            echo -e "$cookie_cmd" | nc 127.0.0.1 "$control_port" > "$result_file" 2>&1
            exit_code=$?
            if [[ $exit_code -eq 0 ]] && grep -q "^250 OK" "$result_file"; then
                cat "$result_file"
                return 0
            fi
        fi
    fi
    
    return 1
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
    
    local result
    result=$(authenticate_control_port "$control_port" "SIGNAL NEWNYM")
    
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
        is_tor=$(echo "$ip" | awk '/"IsTor":\s*true/{print "true"}')
        local ip_addr
        ip_addr=$(echo "$ip" | awk -F'"IP": *"' '{if($2)print substr($2,2,index($2,"\"}")-1)}')
        if [[ -z "$ip_addr" ]]; then
            ip_addr="Unknown"
        fi
        
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

show_circuit_info() {
    local control_port
    control_port=$(get_config_value "ControlPort" "")

    if [[ -z "$control_port" ]] || [[ "$control_port" == "disabled" ]]; then
        gum style --foreground 196 \
            "✗ Control Port is disabled!" \
            "" \
            "Enable it in Configuration Editor first."
        sleep 2
        return 1
    fi

    local result
    result=$(authenticate_control_port "$control_port" "GETINFO circuit-status")

    if [[ $? -ne 0 ]]; then
        gum style --foreground 196 \
            "✗ Failed to authenticate with Tor control port!" \
            "" \
            "Check that ControlPort is enabled and your user has permission."
        sleep 2
        return 1
    fi

    local raw_output="$result"
    local circuits_data=$(echo "$raw_output" | grep -A 100 "^250+circuit-status=" | tail -n +2 | grep -v "^250" | grep -v "^---" | head -n -1)

    if [[ -z "$circuits_data" ]]; then
        clear
        gum style --border rounded --padding "1 2" --border-foreground 226 \
            "No Active Circuits" \
            "" \
            "No active Tor circuits found." \
            "Try requesting a new identity to establish a circuit."
        echo ""
        gum style --foreground 246 "Press any key to continue..."
        read -n 1 -s
        return 0
    fi

    clear
    local circuit_num=0
    local output=""

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        circuit_num=$((circuit_num + 1))
        local circuit_id=$(echo "$line" | awk '{print $1}')
        local circuit_status=$(echo "$line" | awk '{print $2}')
        local purpose=""

        local purpose_match=$(echo "$line" | grep -oP 'PURPOSE=\K[^ ]+')
        [[ -n "$purpose_match" ]] && purpose="$purpose_match"

        local path_info=$(echo "$line" | grep -oP '\$[[^ ]+' | head -3)

        local guard_info middle_info exit_info
        guard_info=$(echo "$path_info" | head -1)
        middle_info=$(echo "$path_info" | head -2 | tail -1)
        exit_info=$(echo "$path_info" | tail -1)

        parse_node_info() {
            local node="$1"
            local fingerprint nickname
            fingerprint=$(echo "$node" | cut -d'$' -f2 | cut -d'~' -f1)
            nickname=$(echo "$node" | cut -d'~' -f2 | cut -d',' -f1)
            echo "$nickname|$fingerprint"
        }

        local guard_nick guard_fp middle_nick middle_fp exit_nick exit_fp

        if [[ -n "$guard_info" ]]; then
            guard_info=$(parse_node_info "$guard_info")
            guard_nick=$(echo "$guard_info" | cut -d'|' -f1)
            guard_fp=$(echo "$guard_info" | cut -d'|' -f2)
        else
            guard_nick="Unknown"
            guard_fp="Unknown"
        fi

        if [[ -n "$middle_info" ]]; then
            middle_info=$(parse_node_info "$middle_info")
            middle_nick=$(echo "$middle_info" | cut -d'|' -f1)
            middle_fp=$(echo "$middle_info" | cut -d'|' -f2)
        else
            middle_nick="Unknown"
            middle_fp="Unknown"
        fi

        if [[ -n "$exit_info" ]]; then
            exit_info=$(parse_node_info "$exit_info")
            exit_nick=$(echo "$exit_info" | cut -d'|' -f1)
            exit_fp=$(echo "$exit_info" | cut -d'|' -f2)
        else
            exit_nick="Unknown"
            exit_fp="Unknown"
        fi

        local panel_content="Circuit #$circuit_id ($circuit_status)"
        panel_content+="\n"
        panel_content+="├── Guard:   $guard_nick (\$$guard_fp)"
        panel_content+="\n"
        panel_content+="├── Middle:  $middle_nick (\$$middle_fp)"
        panel_content+="\n"
        panel_content+="└── Exit:    $exit_nick (\$$exit_fp)"
        panel_content+="\n"
        panel_content+="Purpose: ${purpose:-GENERAL}"

        if [[ $circuit_num -eq 1 ]]; then
            output=$(gum style --border rounded --padding "1 2" --border-foreground 212 "$panel_content")
        else
            output+=$'\n'
            output+=$(gum style --border rounded --padding "1 2" --border-foreground 212 "$panel_content")
        fi
    done <<< "$circuits_data"

    echo "$output"

    echo ""
    gum style --foreground 246 "Press any key to continue..."
    read -n 1 -s
}

################################################################################
# Bandwidth Monitor
################################################################################

human_readable_bytes() {
    local bytes=$1
    if [[ $bytes -lt 1024 ]]; then
        echo "${bytes}B"
    elif [[ $bytes -lt 1048576 ]]; then
        printf "%.2fKB" "$(echo "scale=2; $bytes / 1024" | bc)"
    elif [[ $bytes -lt 1073741824 ]]; then
        printf "%.2fMB" "$(echo "scale=2; $bytes / 1048576" | bc)"
    else
        printf "%.2fGB" "$(echo "scale=2; $bytes / 1073741824" | bc)"
    fi
}

bandwidth_monitor_menu() {
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
    
    if ! pgrep -x tor > /dev/null 2>&1; then
        gum style --foreground 196 \
            "✗ Tor is not running!" \
            "" \
            "Start Tor first."
        sleep 2
        return
    fi
    
    local prev_read=0
    local prev_written=0
    local first_run=1
    
    while true; do
        clear
        gum style --border double --padding "1 2" --border-foreground 82 \
            "📊 Tor Bandwidth Monitor" \
            "" \
            "Live bandwidth statistics (updates every 2s)" \
            "Press Enter to exit"
        echo ""
        
        local result
        result=$(authenticate_control_port "$control_port" "GETINFO traffic/read" "GETINFO traffic/written")
        
        if [[ $? -ne 0 ]]; then
            gum style --foreground 196 "✗ Failed to get bandwidth stats. Check control port."
            echo ""
            gum style --foreground 246 "Press Enter to exit..."
            read -n 1 -s
            return
        fi
        
        local traffic_read=$(echo "$result" | grep "^250-traffic/read=" | cut -d= -f2)
        local traffic_written=$(echo "$result" | grep "^250-traffic/written=" | cut -d= -f2)
        
        if [[ -z "$traffic_read" ]] || [[ -z "$traffic_written" ]]; then
            gum style --foreground 196 "✗ Failed to get bandwidth stats. Check control port."
            echo ""
            gum style --foreground 246 "Press Enter to exit..."
            read -n 1 -s
            return
        fi
        
        local read_rate=0
        local write_rate=0
        
        if [[ $first_run -eq 0 ]]; then
            local read_diff=$((traffic_read - prev_read))
            local write_diff=$((traffic_written - prev_written))
            read_rate=$((read_diff / 2))
            write_rate=$((write_diff / 2))
        fi
        first_run=0
        prev_read=$traffic_read
        prev_written=$traffic_written
        
        gum style --border rounded --padding "1 2" --border-foreground 212 \
            "Total Data Transfer" \
            "" \
            "  $(gum style --foreground 82 "↓ Read:")  $(gum style --bold "$(human_readable_bytes $traffic_read)")" \
            "  $(gum style --foreground 196 "↑ Written:") $(gum style --bold "$(human_readable_bytes $traffic_written)")" \
            "" \
            "Current Rates (bytes/sec)" \
            "" \
            "  $(gum style --foreground 82 "↓ Read Rate:")  $(gum style --bold "$(human_readable_bytes $read_rate)/s")" \
            "  $(gum style --foreground 196 "↑ Write Rate:") $(gum style --bold "$(human_readable_bytes $write_rate)/s")"
        
        echo ""
        gum style --foreground 246 "Press Enter to exit..."
        
        if read -t 2 -n 1; then
            return
        fi
    done
}

################################################################################
# Logs Viewer
################################################################################

view_logs() {
    clear
    gum style --border double --padding "1 2" --border-foreground 212 "Tor Service Logs (last 50 lines)"
    echo ""
    
    if command -v journalctl &> /dev/null && command -v systemctl &> /dev/null && systemctl is-system-running &> /dev/null; then
        journalctl -u tor -n 50 --no-pager | gum format
    elif [[ -f /var/log/tor/log ]]; then
        tail -n 50 /var/log/tor/log | gum format
    else
        gum style --foreground 226 "⚠ Could not find Tor logs." \
            "" \
            "Neither journalctl nor /var/log/tor/log are available."
        echo ""
    fi
    
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
            --height 13 \
            --cursor "→ " \
            "⚙️  Service Control" \
            "📝 Configuration Editor" \
            "🔄 Identity Tools" \
            "📊 Bandwidth Monitor" \
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
            "📊 Bandwidth Monitor")
                bandwidth_monitor_menu
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
