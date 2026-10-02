#!/bin/bash
#################################################################
# deploy_all.sh  (Trino edition)
#
# Run this from ONE control server (the one holding env.json /
# methods.sh / executable.sh). It:
#
#   1. Reads every server hostname out of env.json
#   2. Copies env.json + methods.sh + executable.sh to each one
#      over scp, using a shared SSH key
#   3. SSHes in and runs executable.sh on that server
#
# executable.sh figures out which services belong to whichever host
# it is running on (hostname -I + jq), so the same trio is pushed
# unchanged everywhere. With the Trino env.json that is 172.31.37.239.
#
# Usage:
#   ./deploy_all.sh
#
# Overrides (env vars), if your setup differs from the defaults:
#   SSH_USER=ec2-user SSH_KEY=~/.ssh/prod.pem REMOTE_DIR=Methods ./deploy_all.sh
#################################################################

set -uo pipefail

SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
REMOTE_DIR="${REMOTE_DIR:-Methods}"          # relative to the remote user's $HOME
# ServerAlive* keeps the SSH session open during the long Trino download/extract.
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
          -o ServerAliveInterval=30 -o ServerAliveCountMax=20)

LOCAL_FILES=(env.json methods.sh executable.sh)

FILENAME=$(date +"%d%m%Y%H%M%S")
DEPLOY_LOG="./deploy.${FILENAME}.log"

log() {
    echo "[$(date '+%F %T')] $1" | tee -a "$DEPLOY_LOG"
}

# ---------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------
for f in "${LOCAL_FILES[@]}"; do
    [[ -f "$f" ]] || { echo "Missing required file: $f -- run this from the directory containing env.json/methods.sh/executable.sh"; exit 1; }
done

command -v jq >/dev/null 2>&1 || { echo "jq is required on the control server (apt/yum install jq)"; exit 1; }

if [[ ! -f "$SSH_KEY" ]]; then
    echo "SSH key not found at $SSH_KEY. Set SSH_KEY=/path/to/key or place your key there."
    exit 1
fi
chmod 600 "$SSH_KEY" 2>/dev/null || true

# Refuse to deploy with unfilled placeholders (env.json ships with CHANGE_ME)
if grep -q 'CHANGE_ME' <(jq -r '.servers[].services[] | select(.name=="Trino") | [.config, .auth] | tostring' env.json); then
    echo "env.json still contains CHANGE_ME in the Trino config/auth section (keystore_password / admin_password). Fill them in first."
    exit 1
fi

HOSTS=$(jq -r '.servers[].hostname' env.json)
if [[ -z "$HOSTS" ]]; then
    log "No servers found in env.json"
    exit 1
fi

# This control server's own IPs, so it can deploy to itself locally.
LOCAL_IPS=$(hostname -I)

FAILED_HOSTS=()
TOTAL=0

# ---------------------------------------------------------------
# Deploy loop
# NOTE: every ssh uses -n (and local runs use </dev/null) so they do
# not swallow the here-string feeding this loop -- otherwise only the
# first host would ever be processed when env.json lists several.
# ---------------------------------------------------------------
while IFS= read -r host; do
    [[ -z "$host" ]] && continue
    TOTAL=$((TOTAL + 1))

    if grep -qwF "$host" <<< "$LOCAL_IPS"; then
        log "=== $host (control server itself) === running locally"
        if bash ./executable.sh >> "$DEPLOY_LOG" 2>&1 < /dev/null; then
            log "=== $host: SUCCESS (local) ==="
        else
            log "=== $host: FAILED (local) -- see $DEPLOY_LOG ==="
            FAILED_HOSTS+=("$host")
        fi
        continue
    fi

    log "=== $host === ensuring remote directory exists"
    if ! ssh -n "${SSH_OPTS[@]}" "$SSH_USER@$host" "mkdir -p ~/$REMOTE_DIR" >> "$DEPLOY_LOG" 2>&1; then
        log "=== $host: FAILED (SSH connect / mkdir) -- see $DEPLOY_LOG ==="
        FAILED_HOSTS+=("$host")
        continue
    fi

    log "=== $host === copying env.json, methods.sh, executable.sh"
    if ! scp "${SSH_OPTS[@]}" "${LOCAL_FILES[@]}" "$SSH_USER@$host:~/$REMOTE_DIR/" >> "$DEPLOY_LOG" 2>&1; then
        log "=== $host: FAILED (scp) -- see $DEPLOY_LOG ==="
        FAILED_HOSTS+=("$host")
        continue
    fi

    log "=== $host === running executable.sh remotely (Trino install can take several minutes)"
    # env.json holds credentials -> lock it down on the target
    if ssh -n "${SSH_OPTS[@]}" "$SSH_USER@$host" "cd ~/$REMOTE_DIR && chmod 600 env.json && chmod +x executable.sh && ./executable.sh" >> "$DEPLOY_LOG" 2>&1; then
        log "=== $host: SUCCESS ==="
    else
        log "=== $host: FAILED (remote install) -- see $DEPLOY_LOG ==="
        FAILED_HOSTS+=("$host")
    fi

done <<< "$HOSTS"

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
echo
if [[ ${#FAILED_HOSTS[@]} -eq 0 ]]; then
    log "Deployment complete: $TOTAL/$TOTAL hosts succeeded."
    exit 0
else
    log "Deployment finished with failures on: ${FAILED_HOSTS[*]} ($(( TOTAL - ${#FAILED_HOSTS[@]} ))/$TOTAL succeeded)"
    log "Full details in $DEPLOY_LOG"
    exit 1
fi
