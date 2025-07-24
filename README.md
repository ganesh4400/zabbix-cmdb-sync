# Zabbix CMDB Sync Script

This project provides a Bash script to **synchronize hosts between a CMDB (MariaDB)** and **Zabbix** using the Zabbix API.

---

## 🛠 Features

- 🔄 Automatically **creates or updates** Zabbix hosts based on CMDB records.
- 🎯 Syncs:
  - Host groups
  - Host interfaces (Zabbix agent or SNMP)
  - Templates (based on OS or device type)
  - Macros (like environment, serial number, classification, etc.)
  - Proxies (if available)
- 🧹 Deletes Zabbix hosts not found in the CMDB.
- 🔍 Detects and applies interface changes (e.g. agent ↔ SNMP).

---

## 🧩 Requirements

- Bash (Linux/macOS)
- `jq` (for JSON manipulation)
- MySQL or MariaDB with `cmdb_ci` table
- Zabbix server with API access
- Valid Zabbix API token

---

🧠 Template Assignment Logic

Templates are assigned automatically based on the interface_type and os:

Interface	| OS Pattern	        | Template ID (Example)	| Description.            |
----------------------------------------------------------------------------------|
agent	    | Windows	            | 10081	                | Windows by Zabbix agent.|
agent	    | Linux, Ubuntu, etc.	| 10001	                | Linux by Zabbix agent.  |
snmp	    | Cisco	              | 10218	                | Cisco SNMP Template.    |
snmp	    | Others	            | 10253	                | Generic SNMP Template.  |
----------------------------------------------------------------------------------|
You can adjust template IDs as per your Zabbix setup.

🔐 .gitignore

## 💽 CMDB Table Requirements

The script queries the following fields from a `cmdb_ci` table:

| Column           | Description                          |
|------------------|--------------------------------------|
| `sys_id`         | Unique identifier                    |
| `name`           | Hostname                             |
| `visible_name`   | Display name                         |
| `ip_address`     | Main IP address                      |
| `host_group`     | Zabbix host group name               |
| `interface_type` | `agent` or `snmp`                    |
| `proxy`          | Proxy hostname (optional)           |
| `env`, `os`, etc.| Used for macros                      |

The script also reads values like `serial_number`, `manufacturer`, `model_id`, `department`, `company`, and others for host macros.

---

## ⚙️ Configuration

Edit the script and set the following variables at the top:

```bash
ZABBIX_URL="http://your-zabbix-server/zabbix/api_jsonrpc.php"
ZABBIX_TOKEN="your_zabbix_api_token"

DB_HOST="localhost"
DB_USER="root"
DB_PASS="your_password"
DB_NAME="service_now"

🚀 Usage
chmod +x sync_db_zabbix.sh
./sync_db_zabbix.sh

The script performs:
1. Fetching CMDB entries
2. Creating or updating Zabbix hosts
3. Setting macros and host group
4. Updating interfaces if changed
5. Deleting Zabbix hosts no longer in the CMDB

📁 Output
During execution, the script logs:
✅ Host created
🔄 Host updated
⚙️ Interface updated
❌ Host deleted
⚠️ Warning messages (e.g., proxy not found)

📌 Notes
Templates assigned automatically:
Windows OS → Template ID 10081
Linux-based OS → Template ID 10001
Cisco SNMP → Template ID 10218
Other SNMP → Template ID 10253

Interface check:
Compares and updates IP, port, and interface type.
Replaces the interface if any change is detected.

The script is idempotent: you can run it multiple times safely.

🛡️ Security

Uses Zabbix API token authentication.
Ensure your sync_db_zabbix.sh script is readable only by authorized users:
chmod 700 sync_db_zabbix.sh
