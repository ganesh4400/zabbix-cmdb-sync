#!/bin/bash



ZABBIX_URL=""
ZABBIX_TOKEN=""

DB_NAME="service_now"
DB_USER="root"
DB_PASS=""
DB_HOST=""


TMP_PROCESSED="/tmp/processed_hosts.txt"
> "$TMP_PROCESSED"
declare -a processed_hosts

# Fetch all CMDB entries
query="SELECT sys_id, name, visible_name, ip_address, host_group, interface_type, proxy, env, its, os, os_version, serial_number, classification, u_criticality, location, environment, manufacturer, model_id, ip_address_2, sys_class_name, department, company, vendor, sys_updated_on FROM cmdb_ci;"
echo -e "\n📦 Fetching CMDB entries..."

# API helper function
zabbix_api() {
  curl -s -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $ZABBIX_TOKEN" -d "$1" "$ZABBIX_URL"
}

# Main processing loop
while IFS=$'\t' read -r sys_id name visible_name ip_address host_group interface_type proxy env its os os_version serial_number classification u_criticality location environment manufacturer model_id ip_address_2 sys_class_name department company vendor sys_updated_on; do

  echo -e "➞️  Processing $name | IP: $ip_address | Group: $host_group"

  [[ -z "$ip_address" ]] && echo "⚠️  Missing IP, skipping $name" && continue
  echo "$name" >> "$TMP_PROCESSED"
  processed_hosts+=("$name")

  # Resolve proxy ID
  proxy_id="0"
  if [[ -n "$proxy" ]]; then
    proxy_json=$(zabbix_api "{\"jsonrpc\":\"2.0\",\"method\":\"proxy.get\",\"params\":{\"filter\":{\"host\":[\"$proxy\"]}},\"id\":1}")
    proxy_id=$(echo "$proxy_json" | jq -r '.result[0].proxyid // "0"')
    [[ "$proxy_id" == "0" ]] && echo "⚠️  Proxy '$proxy' not found — assigning as directly monitored."
  fi

  # Resolve host group ID
  group_json=$(zabbix_api "{\"jsonrpc\":\"2.0\",\"method\":\"hostgroup.get\",\"params\":{\"filter\":{\"name\":[\"$host_group\"]}},\"id\":1}")
  group_id=$(echo "$group_json" | jq -r '.result[0].groupid // empty')
  if [[ -z "$group_id" ]]; then
    group_create=$(zabbix_api "{\"jsonrpc\":\"2.0\",\"method\":\"hostgroup.create\",\"params\":{\"name\":\"$host_group\"},\"id\":1}")
    group_id=$(echo "$group_create" | jq -r '.result.groupids[0] // empty')
    echo "🌟 Created host group: $host_group"
  fi

  # Interface type
  iface_type=1
  port="10050"
  if [[ "$interface_type" == "snmp" ]]; then
    iface_type=2
    port="161"
  fi

  # Prepare macros
  macros_json="[]"
  add_macro() {
    local macro_key="$1"
    local macro_value="$2"
    [[ -z "$macro_value" || "$macro_value" == "NULL" ]] && return
    macro_key=$(echo "$macro_key" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9_]/_/g')
    [[ "$macro_key" =~ ^[0-9] ]] && macro_key="ZBX_$macro_key"
    macro_name="{\$$macro_key}"
    macros_json=$(echo "$macros_json" | jq --arg macro "$macro_name" --arg value "$macro_value" '. += [{"macro": $macro, "value": $value}]')
  }

  add_macro ENV "$env"
  add_macro ITS "$its"
  add_macro CLASS "$classification"
  add_macro CRITICALITY "$u_criticality"
  add_macro SERIAL "$serial_number"
  add_macro LOCATION "$location"
  add_macro ZBXENV "$environment"
  add_macro OS "$os"
  add_macro OS_VER "$os_version"
  add_macro MANUFACTURER "$manufacturer"
  add_macro MODEL "$model_id"
  add_macro IP2 "$ip_address_2"
  add_macro CLASS_NAME "$sys_class_name"
  add_macro DEPT "$department"
  add_macro COMPANY "$company"
  add_macro VENDOR "$vendor"
  [[ $iface_type -eq 2 ]] && add_macro SNMP_COMMUNITY "public"

  # Templates
  template_id=""
  if [[ "$interface_type" == "agent" ]]; then
    [[ "$os" =~ [Ww]indows ]] && template_id="10081"
    [[ "$os" =~ [Ll]inux|Ubuntu|CentOS|RHEL|Debian|Alma|Rocky|Oracle|FreeBSD ]] && template_id="10001"
  elif [[ "$interface_type" == "snmp" ]]; then
    [[ "$os" =~ Cisco ]] && template_id="10218" || template_id="10253"
  fi
  template_json=""
  [[ -n "$template_id" ]] && template_json=", \"templates\": [{ \"templateid\": \"$template_id\" }]"

  # Build interface JSON with SNMP details if needed
  iface_json=$(if [[ $iface_type -eq 2 ]]; then
    echo "[{\"type\": 2, \"main\": 1, \"useip\": 1, \"ip\": \"$ip_address\", \"dns\": \"\", \"port\": \"$port\", \"details\": {\"version\": 2, \"bulk\": 1, \"community\": \"{\$SNMP_COMMUNITY}\"}}]"
  else
    echo "[{\"type\": 1, \"main\": 1, \"useip\": 1, \"ip\": \"$ip_address\", \"dns\": \"\", \"port\": \"$port\"}]"
  fi)

  # Check host
  host_check=$(zabbix_api "{\"jsonrpc\":\"2.0\",\"method\":\"host.get\",\"params\":{\"filter\":{\"host\":[\"$name\"]}},\"id\":1}")
  host_id=$(echo "$host_check" | jq -r '.result[0].hostid // empty')

  if [[ -z "$host_id" ]]; then
    # Create host
    create_payload=$(jq -n \
      --arg host "$name" \
      --arg visible "$visible_name" \
      --arg groupid "$group_id" \
      --argjson iface "$iface_json" \
      --argjson macros "$macros_json" \
      '{
        "jsonrpc": "2.0",
        "method": "host.create",
        "params": {
          "host": $host,
          "name": $visible,
          "interfaces": $iface,
          "groups": [{"groupid": $groupid}],
          "macros": $macros
        },
        "id": 1
      }')

    [[ "$proxy_id" != "0" ]] && create_payload=$(echo "$create_payload" | jq --arg proxyid "$proxy_id" '.params.proxy_hostid = $proxyid')
    [[ -n "$template_id" ]] && create_payload=$(echo "$create_payload" | jq --arg templateid "$template_id" '.params.templates = [{"templateid": $templateid}]')

    resp=$(zabbix_api "$create_payload")
    result=$(echo "$resp" | jq -r '.result.hostids[0] // empty')
    if [[ -n "$result" ]]; then
      echo "✅ Created host: $name"
    else
      echo "❌ Failed to create host: $name"
      echo "Request: $create_payload"
      echo "Response: $resp"
    fi
  else
    # Update host
    update_payload=$(jq -n \
      --arg hostid "$host_id" \
      --argjson macros "$macros_json" \
      '{
        "jsonrpc": "2.0",
        "method": "host.update",
        "params": {
          "hostid": $hostid,
          "macros": $macros
        },
        "id": 1
      }')
    update_resp=$(zabbix_api "$update_payload")
    echo "🔄 Updated macros for host: $name"
  fi

done < <(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "$query" -B -N)

# --- Cleanup ---
echo -e "\n🧹 Checking for obsolete hosts..."
zabbix_hosts=$(zabbix_api '{"jsonrpc": "2.0", "method": "host.get", "params": {"output": ["hostid", "host"]}, "id": 1}' | jq -r '.result[] | "\(.hostid)|\(.host)"')

while IFS="|" read -r hostid hostname; do
  if ! grep -Fxq "$hostname" "$TMP_PROCESSED"; then
    echo "❌ Deleting $hostname (not found in CMDB)"
    zabbix_api "{\"jsonrpc\": \"2.0\", \"method\": \"host.delete\", \"params\": [\"$hostid\"], \"id\": 1}" > /dev/null
  fi

done <<< "$zabbix_hosts"

rm -f "$TMP_PROCESSED"
echo "✅ CMDB to Zabbix sync complete."

