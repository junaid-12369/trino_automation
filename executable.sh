#!/bin/bash

# Always run relative to this script's own directory, so ./methods.sh
# and env.json resolve no matter where it was launched from.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# 0. jq is required to read env.json. Bootstrap it if this host lacks it
#    (the control server is checked in deploy_all.sh, but the remote
#    target servers are not).
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not found on $(hostname) - installing ..."
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -y && sudo apt-get install -y jq
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y jq
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y jq
    fi
    command -v jq >/dev/null 2>&1 || { echo "Could not install jq - install it manually and re-run."; exit 1; }
fi

# 1. Source the methods file so all functions become available in memory
source ./methods.sh

# 2. Identify the current server's hostname
CURRENT_HOST=$(hostname -I | awk '{print $1}')

# 3. Read the install commands from env.json for this specific host using 'jq'
INSTALL_CMDS=$(jq -r --arg host "$CURRENT_HOST" '.servers[] | select(.hostname == $host) | .services[].install_cmd' "$ENV_JSON")

if [[ -z "$INSTALL_CMDS" ]]; then
    echo "No install commands found for host $CURRENT_HOST in env.json"
    exit 1
fi

# 4. Loop through and execute each command, one per line.
while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    echo "Executing: $cmd"
    eval "$cmd"

    if [ $? -eq 0 ]; then
        echo "Successfully executed: $cmd"
    else
        echo "Error executing: $cmd"
        exit 1
    fi
done <<< "$INSTALL_CMDS"
