# torman

**TorMan** — Advanced Tor Management Script with a modern gum-based TUI.

A professional Bash script for managing Tor services, configuration, and onion services on Debian/Arch-based systems.

---

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/K7gler/torman/main/torman.sh -o torman.sh && chmod +x torman.sh && sudo ./torman.sh
```

Auto-installs missing dependencies (gum, tor, curl, netcat-openbsd) on first run.

---

## Requirements

- **Root access** — must be run as root or via sudo
- **Debian/Arch-based Linux** — designed for `apt`/`dnf`-based systems
- **Internet connection** — required for first-run dependency installation
- **systemd** — for service management (with fallback for log viewing)

---

## Key Architecture Features

### Safe Configuration Management

The script uses **block-based editing** with markers (`# BEGIN TORMAN_CONFIG` / `# END TORMAN_CONFIG`):
- Never overwrites the entire `torrc`
- Only modifies content between markers
- Preserves user's manual configurations outside the block
- Uses `awk` for surgical precision when updating values

### New Safety Features

- **Distro-aware Tor user detection** — auto-detects `debian-tor` (Debian/Ubuntu) vs `tor` (Arch), or falls back to the running Tor process owner
- **Automatic torrc backups** — every mutation creates a timestamped backup; keeps the last 5
- **Permission preservation** — original file permissions are saved and restored after edits
- **Temp file cleanup** — `trap` ensures `mktemp` files are removed even on Ctrl-C
- **Config validation** — `tor --verify-config` is run before every reload; on failure, user is offered a restore from backup
- **Portable grep** — no `grep -oP`; all JSON parsing uses `awk`

### Environment-Variable Overrides

```bash
TORRC_PATH=/custom/path/torrc TOR_DATA_DIR=/custom/data ./torman.sh
```

---

## Feature Highlights

### 1. Dashboard
- Real-time Tor status (Active/Inactive)
- Current exit IP (fetched via Tor's SOCKS proxy)
- Beautiful gum-powered TUI with emojis

### 2. Service Control
- Start/Stop/Restart/Reload operations
- Enable/Disable on boot (systemctl)
- **Panic Stop** — force kills all Tor processes

### 3. Configuration Editor
- SOCKS Port configuration (with numeric validation and port range checking)
- Control Port toggle (with security warnings)
- **StrictNodes toggle** — forces Tor to only use specified ExitNodes (with warning)
- Exit Nodes setting with **{xx}** format validation
- View current managed configuration

### 4. Onion Service Manager
- **List Services**: Parses `/var/lib/tor/` and displays `.onion` hostnames
- **Create New**:
  - Prompts for service name, local port, Tor port
  - Validates port ranges (1-65535), warns on privileged ports (<1024)
  - Warns on port collisions via `ss`/`netstat`
  - Warns if nothing is listening on the local port
  - Creates directory with correct ownership (`debian-tor:debian-tor` or `tor:tor`)
  - Sets permissions (`chmod 700`)
  - Appends config to torrc block
  - Reloads Tor and waits for hostname generation
  - Displays QR code (if `qrencode` installed)
- **Delete**: Removes ALL associated `HiddenServicePort` lines and the service directory

### 5. Identity Tools
- **New Identity (NEWNYM)**: Sends `SIGNAL NEWNYM` via netcat to control port
- **Cookie authentication support** — falls back to reading `/var/lib/tor/control_auth_cookie` if empty `AUTHENTICATE ""` fails
- **Reliable exit-code handling** — `gum spin` no longer swallows `nc` exit codes
- **Check IP**: Queries `check.torproject.org/api/ip` via SOCKS
- **Check Connectivity**: Verifies Tor is working

### 6. Logs Viewer
- Uses `journalctl -u tor` on systemd systems
- Falls back to `/var/log/tor/log` on non-systemd systems
- Shows last 50 lines with gum formatting

### 7. Error Handling
- Missing dependencies → Offers to install via apt
- Missing torrc → Exits with error
- Control port disabled → Warns user in Identity Tools
- Service directory conflicts → Prevents overwrites
- **Config validation** → `tor --verify-config` before every reload; offers backup restore on failure
- **Temp file cleanup** → `trap` ensures cleanup even on interrupt

---

## Technical Details

### Config Block Logic

```bash
# The script ONLY edits between these markers:
# BEGIN TORMAN_CONFIG
SocksPort 9050
ControlPort 9051
StrictNodes 0
ExitNodes {us},{de}
HiddenServiceDir /var/lib/tor/my-service/
HiddenServicePort 80 127.0.0.1:80
# END TORMAN_CONFIG
```

**Why This Works:**
- Uses `awk` to extract/rebuild the block
- Leaves everything **outside** the markers untouched
- Prevents conflicts with manual edits
- Clean separation of concerns

### Backup & Validation Flow

```
set_config_value()
    │
    ├── backup_torrc()         → creates timestamped backup, keeps last 5
    │       │
    │       └── saves original permissions
    │
    ├── awk processes file     → surgical update within markers
    │
    ├── restore_permissions()  → restores original file mode
    │
    └── validate_tor_config() → tor --verify-config
            │
            ├── OK  → apply changes
            │
            └── FAIL → offer restore from latest backup
```

### Tor User Detection Flow

```
get_tor_user()
    │
    ├── pgrep for running tor process
    │       │
    │       └── found → use process owner (ps -o user=)
    │
    ├── not found → check if 'debian-tor' user exists
    │       │
    │       └── yes → use 'debian-tor'
    │
    └── fallback → use 'tor' (Arch default)
```

### NEWNYM Implementation

```bash
# 1. Try empty authentication first
echo -e 'AUTHENTICATE ""\nSIGNAL NEWNYM\nQUIT' | nc 127.0.0.1 9051

# 2. If that fails, try cookie authentication
xxd -p /var/lib/tor/control_auth_cookie | tr -d '\n'
# → AUTHENTICATE <hex_cookie>\nSIGNAL NEWNYM\nQUIT
```

---

## Security Considerations

- **Root check** enforced at startup
- **Control Port** only bound to localhost (127.0.0.1)
- **Confirmation prompts** for panic stop, service deletion
- **Proper ownership** for hidden service directories (`chown`, `chmod 700`)
- **Config block isolation** prevents accidental data loss
- **Automatic backups** before every torrc mutation; easy restore on failure
- **Permission preservation** — original file permissions restored after edits
- **Config validation** — `tor --verify-config` catches errors before reload

---

## Dependencies

| Package | Purpose | Auto-Install |
|---------|---------|--------------|
| `gum` | TUI framework | Yes (from Charm repo) |
| `tor` | Tor daemon | Yes (apt) |
| `curl` | IP checking | Yes (apt) |
| `netcat-openbsd` | Control port communication | Yes (apt) |
| `qrencode` | QR codes for .onion addresses | Optional |

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TORRC_PATH` | `/etc/tor/torrc` | Path to Tor configuration file |
| `TOR_DATA_DIR` | `/var/lib/tor` | Base directory for Tor data (onion services) |

Example:
```bash
sudo TORRC_PATH=/etc/tor/torrc TOR_DATA_DIR=/var/lib/tor ./torman.sh
```

---

## Roadmap / TODO

Planned features for future releases:

- Bandwidth monitoring and statistics
- Circuit information display (current path through network)
- Backup/restore for hidden service private keys
- Interactive torrc syntax validation with suggestions
- Multi-instance support (manage multiple Tor configs)
