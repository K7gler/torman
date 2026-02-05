# torman
Tor Service management script

## 🎯 **Key Architecture Features**

### **Safe Configuration Management**
The script uses **block-based editing** with markers (`# BEGIN TORMAN_CONFIG` / `# END TORMAN_CONFIG`):
- ✅ **Never overwrites** the entire `torrc`
- ✅ Only modifies content **between markers**
- ✅ Preserves user's manual configurations outside the block
- ✅ Uses `awk` for surgical precision when updating values

### **Modular Design**
The script is organized into logical function groups:
- **Dependency Management** - Checks, installs gum/tor/curl/netcat
- **Config Management** - `get_config_value()`, `set_config_value()`, `remove_config_value()`
- **Service Control** - Start/stop/restart/reload/panic kill
- **Onion Service Wizard** - Create/list/delete with proper permissions
- **Identity Tools** - NEWNYM signal, IP checking

## 🚀 **Feature Highlights**

### **1. Dashboard**
- Real-time Tor status (Active/Inactive)
- Current exit IP (fetched via Tor's SOCKS proxy)
- Beautiful gum-powered TUI with emojis

### **2. Service Control**
- Start/Stop/Restart/Reload operations
- Enable/Disable on boot (systemctl)
- **Panic Stop** - Force kills all Tor processes

### **3. Configuration Editor**
- SOCKS Port configuration (validates numeric input)
- Control Port toggle (with security warnings)
- Exit Nodes setting (country codes like `{us},{de}`)
- View current managed configuration

### **4. Onion Service Manager** (Full Wizard)
- **List Services**: Parses `/var/lib/tor/` and displays `.onion` hostnames
- **Create New**:
  - Prompts for service name, local port, Tor port
  - Creates directory with correct ownership (`debian-tor:debian-tor`)
  - Sets permissions (`chmod 700`)
  - Appends config to torrc block
  - Reloads Tor and waits for hostname generation
  - Displays QR code (if `qrencode` installed)
- **Delete**: Removes config block and directory (with confirmation)

### **5. Identity Tools**
- **New Identity**: Sends `SIGNAL NEWNYM` via netcat to control port
- **Check IP**: Queries `check.torproject.org/api/ip` via SOCKS
- **Check Connectivity**: Verifies Tor is working

### **6. Error Handling**
- Missing dependencies → Offers to install via apt
- Missing torrc → Exits with error
- Control port disabled → Warns user in Identity Tools
- Service directory conflicts → Prevents overwrites

## 📋 **Usage Instructions**

```bash
# Make executable
chmod +x torman.sh

# Run as root
sudo ./torman.sh
```

### **First Run**
1. If `gum` is missing, it offers to install from Charm's repository
2. Checks for `tor`, `curl`, `netcat-openbsd` and offers to install
3. Creates the managed config block in torrc automatically
4. Launches the interactive dashboard

## 🔧 **Technical Details**

### **Config Block Logic** (Core Safety Feature)
```bash
# The script ONLY edits between these markers:
# BEGIN TORMAN_CONFIG
SocksPort 9050
ControlPort 9051
ExitNodes {de}
HiddenServiceDir /var/lib/tor/my-service/
HiddenServicePort 80 127.0.0.1:80
# END TORMAN_CONFIG
```

**Why This Works:**
- Uses `awk` to extract/rebuild the block
- Leaves everything **outside** the markers untouched
- Prevents conflicts with manual edits
- Clean separation of concerns

### **Onion Service Permissions**
The script properly sets:
```bash
chown debian-tor:debian-tor /var/lib/tor/service-name
chmod 700 /var/lib/tor/service-name
```
This is **critical** - Tor refuses to start if permissions are wrong.

### **NEWNYM Implementation**
```bash
echo -e 'AUTHENTICATE ""\nSIGNAL NEWNYM\nQUIT' | nc 127.0.0.1 9051
```
- Authenticates (empty password for localhost)
- Sends NEWNYM signal (requests new circuit)
- Properly closes connection

## 🎨 **Visual Design**

The script uses `gum` styling throughout:
- **Borders**: Rounded/double borders for menus
- **Colors**: Status-based (green=active, red=inactive, yellow=warnings)
- **Spinners**: Shows progress for long operations
- **Confirmations**: Uses `gum confirm` for destructive actions

## 🔒 **Security Considerations**

✅ **Root Check**: Enforced at startup  
✅ **Control Port**: Only bound to localhost (127.0.0.1)  
✅ **Confirmation Prompts**: For panic stop, service deletion  
✅ **Permission Hardening**: Proper ownership for hidden service dirs  
✅ **No Blind Overwrites**: Config block isolation prevents data loss

## 📦 **Dependencies**

| Package | Purpose | Auto-Install |
|---------|---------|--------------|
| `gum` | TUI framework | ✅ Yes (from Charm repo) |
| `tor` | Tor daemon | ✅ Yes (apt) |
| `curl` | IP checking | ✅ Yes (apt) |
| `netcat-openbsd` | Control port communication | ✅ Yes (apt) |
| `qrencode` | QR codes for .onion addresses | ⚠️ Optional |
- Bandwidth monitoring?
- Circuit information display?
- Backup/restore for hidden service keys?
