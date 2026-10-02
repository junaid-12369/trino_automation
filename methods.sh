#!/bin/bash

#########################################################
# methods.sh  (Trino edition)
#
# ENV.JSON LOCATION
# Resolved once, relative to methods.sh's own location -- NOT the
# caller's current directory -- so every jq lookup is independent
# of cwd.
#########################################################
METHODS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_JSON="$METHODS_DIR/env.json"

#########################################################
# COMMON FUNCTIONS
#########################################################

log_info() {
    echo "[$(date '+%F %T')] [INFO] $1" >> "$ACCESS_LOG"
}
log_error() {
    echo "[$(date '+%F %T')] [ERROR] $1" >> "$ERROR_LOG"
}

#########################################################
# TRINO FUNCTIONS
#
# trino_install reads this host's Trino block from env.json, turns it
# into the environment variables the (embedded) automated installer
# expects, and runs that installer as root. The installer is the
# unmodified trino_install.sh, embedded further down in
# trino_write_installer, so this trio stays a self-contained
# 4-file deployment.
#
# Layout (from DiskPath, same convention as the Apache install):
#   TRINO_HOME = <DiskPath>/apps/trino
#   SOURCE_DIR = <DiskPath>/softwares      (downloaded archives)
#########################################################

# Print to stderr AND to the error log (log_error alone is file-only,
# which would leave deploy_all.sh's log with no visible reason).
trino_fail() {
    echo "[$(date '+%F %T')] [ERROR] $1" >&2
    log_error "$1"
}

# trino_svc '<jq filter>' -> applies the filter to THIS host's Trino service object
trino_svc() {
    jq -r --arg host "$CURRENT_HOST" \
        "first(.servers[] | select(.hostname==\$host) | .services[] | select(.name==\"Trino\")) | $1" \
        "$ENV_JSON"
}

# trino_flag '<jq path>' <default: true|false> -> prints 1 or 0
trino_flag() {
    local v
    v=$(trino_svc "($1) | if . == null then $2 else . end")
    [[ "$v" == "true" ]] && echo 1 || echo 0
}

# trino_get '<jq path>' -> prints value ("" if unset); fails on CHANGE_ME placeholders
trino_get() {
    local v
    v=$(trino_svc "($1) // empty") || return 1
    if [[ "$v" == CHANGE_ME* ]]; then
        trino_fail "env.json: Trino setting '$1' is still CHANGE_ME"
        return 1
    fi
    printf '%s' "$v"
}

trino_export_const() {   # <file> <ENV_VAR> <value>
    printf 'export %s=%q\n' "$2" "$3" >> "$1"
}

trino_export() {         # <file> <ENV_VAR> <jq path> [required=0|1]
    local f="$1" name="$2" path="$3" required="${4:-0}" v
    v=$(trino_get "$path") || return 1
    if [[ -z "$v" ]]; then
        if [[ "$required" == "1" ]]; then
            trino_fail "env.json: required Trino setting '$path' is empty"
            return 1
        fi
        return 0
    fi
    trino_export_const "$f" "$name" "$v"
}

#########################################################

trino_init_vars() {
    ACCESS_LOG="$METHODS_DIR/trino.access.log"
    ERROR_LOG="$METHODS_DIR/trino.error.log"
    touch "$ACCESS_LOG" "$ERROR_LOG" || { echo "Cannot write logs in $METHODS_DIR" >&2; return 1; }

    CURRENT_HOST=$(hostname -I | awk '{print $1}')
    if [[ "$(trino_svc '.name // empty')" != "Trino" ]]; then
        trino_fail "No Trino service defined for host $CURRENT_HOST in env.json"
        return 1
    fi

    DISK_PATH=$(trino_svc '.DiskPath // empty')
    if [[ -z "$DISK_PATH" ]]; then
        trino_fail "Could not determine DiskPath for Trino from env.json"
        return 1
    fi
    DISK_PATH="${DISK_PATH%/}"     # "/" becomes "" so paths below are not double-slashed

    TRINO_HOME="$DISK_PATH/apps/trino"
    SOURCE_DIR="$DISK_PATH/softwares"
    TRINO_INSTALLER="$METHODS_DIR/trino_install.sh"
    log_info "Trino: host=$CURRENT_HOST TRINO_HOME=$TRINO_HOME SOURCE_DIR=$SOURCE_DIR"
}

#########################################################
# trino_build_env_file <file>
# Translates env.json -> `export VAR=value` lines (shell-quoted with
# %q, so passwords containing $ ! ' " etc. are safe). The file is
# mode 600 and removed right after the installer runs; secrets never
# appear on a command line / in `ps`.
#########################################################
trino_build_env_file() {
    local f="$1" pair host auth pg_on ice_on nes_on dru_on
    : > "$f"

    trino_export_const "$f" AUTOMATED 1
    trino_export_const "$f" TRINO_HOME "$TRINO_HOME"
    trino_export_const "$f" SOURCE_DIR "$SOURCE_DIR"

    host=$(trino_get '.config.coordinator_host') || return 1
    trino_export_const "$f" TRINO_HOST "${host:-$CURRENT_HOST}"

    for pair in \
        "TRINO_VERSION:.config.version" \
        "CLI_VERSION:.config.cli_version" \
        "SERVICE_USER:.config.service_user" \
        "HTTPS_PORT:.config.https_port" \
        "NODE_ENVIRONMENT:.config.node_environment" \
        "NODE_ID:.config.node_id" \
        "HEAP_SIZE:.config.heap_size"
    do
        trino_export "$f" "${pair%%:*}" "${pair#*:}" || return 1
    done
    trino_export "$f" KEYSTORE_PASSWORD .config.keystore_password 1 || return 1

    # ---- authentication ----
    auth=$(trino_flag '.auth.enabled' true)
    trino_export_const "$f" ENABLE_PASSWORD_AUTH "$auth"
    if [[ "$auth" == "1" ]]; then
        trino_export "$f" ADMIN_USERNAME .auth.admin_username 1 || return 1
        trino_export "$f" ADMIN_PASSWORD .auth.admin_password 1 || return 1
    fi

    # ---- catalogs (all off unless enabled in env.json) ----
    pg_on=$(trino_flag  '.catalogs.postgresql.enabled'   false)
    ice_on=$(trino_flag '.catalogs.iceberg_azure.enabled' false)
    nes_on=$(trino_flag '.catalogs.nessie.enabled'        false)
    dru_on=$(trino_flag '.catalogs.druid.enabled'         false)
    trino_export_const "$f" ENABLE_PG            "$pg_on"
    trino_export_const "$f" ENABLE_ICEBERG_AZURE "$ice_on"
    trino_export_const "$f" ENABLE_NESSIE        "$nes_on"
    trino_export_const "$f" ENABLE_DRUID         "$dru_on"

    if [[ "$pg_on" == "1" || "$ice_on" == "1" ]]; then
        # Iceberg-on-Azure keeps its JDBC catalog in PostgreSQL, so both share these.
        trino_export "$f" PG_HOST     .catalogs.postgresql.host     1 || return 1
        trino_export "$f" PG_PORT     .catalogs.postgresql.port     1 || return 1
        trino_export "$f" PG_DB       .catalogs.postgresql.database 1 || return 1
        trino_export "$f" PG_USER     .catalogs.postgresql.user     1 || return 1
        trino_export "$f" PG_PASSWORD .catalogs.postgresql.password 1 || return 1
    fi
    if [[ "$pg_on" == "1" ]]; then
        trino_export "$f" PG_CATALOG_NAME .catalogs.postgresql.catalog_name 1 || return 1
    fi
    if [[ "$ice_on" == "1" ]]; then
        trino_export "$f" AZURE_STORAGE_ACCOUNT      .catalogs.iceberg_azure.storage_account    1 || return 1
        trino_export "$f" AZURE_CONTAINER            .catalogs.iceberg_azure.container          1 || return 1
        trino_export "$f" AZURE_WAREHOUSE_PATH       .catalogs.iceberg_azure.warehouse_path     1 || return 1
        trino_export "$f" AZURE_ACCESS_KEY           .catalogs.iceberg_azure.access_key         1 || return 1
        trino_export "$f" ICEBERG_JDBC_CATALOG_NAME  .catalogs.iceberg_azure.jdbc_catalog_name  1 || return 1
    fi
    if [[ "$nes_on" == "1" ]]; then
        trino_export "$f" NESSIE_URI       .catalogs.nessie.uri        1 || return 1
        trino_export "$f" NESSIE_REF       .catalogs.nessie.ref        1 || return 1
        trino_export "$f" NESSIE_WAREHOUSE .catalogs.nessie.warehouse  1 || return 1
        trino_export "$f" AWS_REGION       .catalogs.nessie.aws_region 1 || return 1
        # blank keys = use the instance role / default AWS credential chain
        trino_export "$f" AWS_ACCESS_KEY   .catalogs.nessie.aws_access_key || return 1
        trino_export "$f" AWS_SECRET_KEY   .catalogs.nessie.aws_secret_key || return 1
    fi
    if [[ "$dru_on" == "1" ]]; then
        trino_export "$f" DRUID_HOST     .catalogs.druid.host     1 || return 1
        trino_export "$f" DRUID_PORT     .catalogs.druid.port     1 || return 1
        trino_export "$f" DRUID_USER     .catalogs.druid.user     1 || return 1
        trino_export "$f" DRUID_PASSWORD .catalogs.druid.password 1 || return 1
    fi
    chmod 600 "$f"
    log_info "Trino: installer environment generated (pg=$pg_on iceberg_azure=$ice_on nessie=$nes_on druid=$dru_on auth=$auth)"
}

#########################################################
# trino_write_installer <dest>
# Writes the embedded, unmodified trino_install.sh to <dest>.
#########################################################
trino_write_installer() {
    local dest="$1"
    cat > "$dest" <<'__TRINO_INSTALLER_EOF__'
#!/bin/bash
#================================================================
# trino_install.sh
# Fully automated installation of a single-node Trino
# (coordinator + worker on one machine) following the same
# conventions as airflow_install.sh / iceberg_install.sh
# (idempotent, interactive OR fully non-interactive, systemd
# service, structured logging, safe defaults).
#
# Built from the manual install notes:
#   - Java (Temurin, installed side-by-side, system java untouched):
#     Java 25 for Trino >= 479, Java 24 for older releases (auto-selected)
#   - Trino server tarball (Maven Central URL / GitHub Releases fallback) -> TRINO_HOME (/opt/trino)
#   - HTTPS-only coordinator (8443) with a PKCS12 keystore
#   - PASSWORD authentication (file authenticator, bcrypt password file)
#   - optional catalogs: PostgreSQL, Iceberg (JDBC + Azure ADLS Gen2),
#     Nessie (S3), Druid
#   - Trino CLI + /usr/local/bin/trino wrapper
#   - systemd unit running `bin/launcher run`
#
# Interactive usage:
#   sudo ./trino_install.sh
#
# Non-interactive (AUTOMATED) usage - example with every catalog:
#   AUTOMATED=1 TRINO_HOME=/opt/trino TRINO_VERSION=483 \
#   TRINO_HOST=10.64.4.107 KEYSTORE_PASSWORD='KeystorePass1' \
#   ADMIN_USERNAME=admin ADMIN_PASSWORD='AdminPass123' \
#   ENABLE_PG=1 ENABLE_ICEBERG_AZURE=1 ENABLE_NESSIE=1 ENABLE_DRUID=1 \
#   PG_HOST=... PG_PORT=... PG_DB=... PG_USER=... PG_PASSWORD='...' \
#   AZURE_STORAGE_ACCOUNT=... AZURE_CONTAINER=... AZURE_ACCESS_KEY='...' \
#   NESSIE_WAREHOUSE=s3://bucket/warehouse AWS_ACCESS_KEY=... AWS_SECRET_KEY=... \
#   DRUID_HOST=... DRUID_PASSWORD='...' \
#   sudo -E ./trino_install.sh
# Use SINGLE quotes around passwords so the shell does not expand $ or !.
#
# NOTES
#  * No credential has a default. Every file that contains a secret
#    (config.properties, catalog/*.properties, password.db, keystore)
#    is written chmod 600. Secrets are never written to the log or
#    the summary file.
#  * All catalogs are OFF unless you enable them (ENABLE_PG,
#    ENABLE_ICEBERG_AZURE, ENABLE_NESSIE, ENABLE_DRUID = 1).
#  * SHARED_SECRET (internal communication) is generated randomly
#    unless you export one. Export the same value on every node if
#    you later add workers.
#  * Java (24 or 25, see above) is installed under /usr/lib/jvm/temurin-<N>-jdk and used
#    only by the trino service and CLI wrapper. `update-alternatives`
#    is NOT touched, so other Java apps on the machine (e.g. the
#    Gravitino Iceberg REST server on Java 17) keep working.
#  * The generated self-signed certificate is imported into that
#    JDK's cacerts so Trino can talk to itself over HTTPS
#    (internal-communication.https.required=true). Set
#    IMPORT_CERT_TO_JVM=0 to skip this if you supply a CA-signed cert.
#  * Trino, catalogs and password file are rewritten on every run;
#    the first pre-existing version of each file is kept as <file>.bkp.
#
# In AUTOMATED mode every variable falls back to its documented
# default if not exported, EXCEPT it will never silently accept an
# invalid/unsafe value (bad port, system directory as TRINO_HOME,
# empty password, etc.) - it dies with a clear message instead of
# hanging on a prompt that will never be answered.
#================================================================

# Re-exec under bash if started by sh/dash (e.g. shebang not on line 1, or "sh script.sh")
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/trino_install.$(date +%Y%m%d%H%M%S).log"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

AUTOMATED="${AUTOMATED:-0}"

# ---------- colors / logging ----------
C_GREEN="\033[0;32m"; C_YELLOW="\033[1;33m"; C_RED="\033[0;31m"; C_BLUE="\033[0;34m"; C_RESET="\033[0m"

log()  { echo -e "${C_BLUE}[$(date +'%F %T')]${C_RESET} $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${C_GREEN}[$(date +'%F %T')] [OK]${C_RESET} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${C_YELLOW}[$(date +'%F %T')] [WARN]${C_RESET} $*" | tee -a "$LOG_FILE"; }
# die writes to STDERR so it is still visible when called inside $( ... )
die()  { echo -e "${C_RED}[$(date +'%F %T')] [ERROR]${C_RESET} $*" | tee -a "$LOG_FILE" >&2; exit 1; }

# set_var VAR prompt_fn args...  -> runs the prompt in a subshell and aborts the
# WHOLE script if the prompt dies (a plain VAR=$(...) would swallow the exit).
set_var() {
    local __name="$1" __out
    shift
    __out="$("$@")" || exit 1
    printf -v "$__name" '%s' "$__out"
}

# ---------- pre-flight ----------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root (use sudo)."
    fi
}

# ---------- OS detection ----------
detect_os() {
    if [ ! -f /etc/os-release ]; then
        die "Cannot detect OS: /etc/os-release not found. Unsupported system."
    fi
    . /etc/os-release
    OS_ID="${ID}"
    OS_LIKE="${ID_LIKE:-}"

    case "$OS_ID $OS_LIKE" in
        *debian*|*ubuntu*)
            OS_FAMILY="debian"
            PKG_UPDATE="apt-get update -y"
            PKG_INSTALL="apt-get install -y"
            BASE_PKGS="wget curl tar gzip ca-certificates openssl python3 apache2-utils"
            ;;
        *rhel*|*centos*|*fedora*|*rocky*|*almalinux*|*amzn*)
            OS_FAMILY="rhel"
            if command -v dnf >/dev/null 2>&1; then
                PKG_UPDATE="dnf makecache -y"
                PKG_INSTALL="dnf install -y"
            else
                PKG_UPDATE="yum makecache -y"
                PKG_INSTALL="yum install -y"
            fi
            # curl is intentionally omitted (curl-minimal conflicts on Amazon Linux); checked below
            BASE_PKGS="wget tar gzip ca-certificates openssl python3 httpd-tools"
            ;;
        *suse*|*sles*)
            OS_FAMILY="suse"
            PKG_UPDATE="zypper refresh"
            PKG_INSTALL="zypper install -y"
            BASE_PKGS="wget curl tar gzip ca-certificates openssl python3 apache2-utils"
            ;;
        *)
            die "Unsupported OS family (ID=$OS_ID ID_LIKE=$OS_LIKE). Supported: Debian/Ubuntu, RHEL/CentOS/Rocky/Alma/Fedora/Amazon Linux, SUSE/SLES."
            ;;
    esac
    ok "Detected OS: $OS_ID (family: $OS_FAMILY)"
}

install_deps() {
    log "Installing base packages for family '$OS_FAMILY' ..."
    $PKG_UPDATE >> "$LOG_FILE" 2>&1
    # shellcheck disable=SC2086
    $PKG_INSTALL $BASE_PKGS >> "$LOG_FILE" 2>&1 \
        || die "Base package installation failed. See $LOG_FILE"
    command -v curl >/dev/null 2>&1 || die "curl is required but not installed. Install it and re-run."
    if [ "$ENABLE_PASSWORD_AUTH" = "1" ]; then
        command -v htpasswd >/dev/null 2>&1 || die "htpasswd not found after package install (needed for the password file)."
    fi
    ok "Base packages installed."
}

# ---------- prompt helpers (same shape as airflow/iceberg scripts) ----------
prompt_nonempty() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" val
    if [ "$AUTOMATED" = "1" ]; then
        val="${current_val:-$default_val}"
        [ -n "$val" ] || die "AUTOMATED mode: empty value not allowed for: $prompt_text"
        echo "$val"
        return 0
    fi
    while true; do
        if [ -n "$default_val" ]; then
            read -rp "$prompt_text [$default_val]: " val
        else
            read -rp "$prompt_text: " val
        fi
        val="${val:-$default_val}"
        if [ -n "$val" ]; then
            echo "$val"
            return 0
        fi
        echo "  Value cannot be empty." >&2
    done
}

# prompt_secret <text> <current_val> [min_len] [allow_empty]
# Masks interactive input, never shows a default, never logs the value.
prompt_secret() {
    local prompt_text="$1" current_val="${2:-}" min_len="${3:-1}" allow_empty="${4:-0}" val
    if [ "$AUTOMATED" = "1" ]; then
        val="$current_val"
        if [ -z "$val" ]; then
            [ "$allow_empty" = "1" ] && return 0
            die "AUTOMATED mode: empty value not allowed for: $prompt_text"
        fi
        [ ${#val} -ge "$min_len" ] || die "AUTOMATED mode: $prompt_text must be at least $min_len characters."
        echo "$val"
        return 0
    fi
    while true; do
        read -rsp "$prompt_text: " val
        echo >&2
        val="${val:-$current_val}"
        if [ -z "$val" ] && [ "$allow_empty" = "1" ]; then
            return 0
        fi
        if [ ${#val} -ge "$min_len" ] && [ -n "$val" ]; then
            echo "$val"
            return 0
        fi
        echo "  Value must be at least $min_len characters." >&2
    done
}

valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

prompt_port() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" val
    if [ "$AUTOMATED" = "1" ]; then
        val="${current_val:-$default_val}"
        valid_port "$val" || die "AUTOMATED mode: invalid port '$val' for: $prompt_text"
        echo "$val"
        return 0
    fi
    while true; do
        if [ -n "$default_val" ]; then
            read -rp "$prompt_text [$default_val]: " val
        else
            read -rp "$prompt_text: " val
        fi
        val="${val:-$default_val}"
        if valid_port "$val"; then
            echo "$val"
            return 0
        fi
        echo "  '$val' is not a valid port (1-65535), try again." >&2
    done
}

# ---------- safe absolute-path prompt (rejects '/', empty, /opt itself and other system roots) ----------
prompt_safe_dir() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" val
    while true; do
        if [ "$AUTOMATED" = "1" ]; then
            val="${current_val:-$default_val}"
        else
            read -rp "$prompt_text [$default_val]: " val
            val="${val:-$default_val}"
        fi
        val="${val%/}"
        case "$val" in
            ""|"/"|"/root"|"/home"|"/etc"|"/usr"|"/var"|"/bin"|"/sbin"|"/lib"|"/boot"|"/sys"|"/proc"|"/dev"|"/opt"|"/tmp"|"/mnt")
                [ "$AUTOMATED" = "1" ] && die "AUTOMATED mode: refusing to use '$val' - choose a dedicated sub-directory (e.g. /opt/trino)."
                echo "  Refusing to use '$val' - choose a dedicated sub-directory (e.g. /opt/trino)." >&2
                continue
                ;;
        esac
        if [[ "$val" != /* ]]; then
            [ "$AUTOMATED" = "1" ] && die "AUTOMATED mode: path must be absolute, got '$val'."
            echo "  Path must be absolute (start with /)." >&2
            continue
        fi
        echo "$val"
        return 0
    done
}

prompt_yesno() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" val label
    [ "$default_val" = "1" ] && label="y" || label="n"
    while true; do
        if [ "$AUTOMATED" = "1" ]; then
            val="${current_val:-$default_val}"
        else
            read -rp "$prompt_text [$label] (y/n): " val
            val="${val:-$default_val}"
        fi
        val="$(echo "$val" | tr '[:upper:]' '[:lower:]')"
        case "$val" in
            y|yes|1) echo "1"; return 0 ;;
            n|no|0)  echo "0"; return 0 ;;
            *)
                [ "$AUTOMATED" = "1" ] && die "Expected y/n, got '$val' for: $prompt_text"
                echo "  Please answer y or n." >&2
                ;;
        esac
    done
}

prompt_heap() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" val
    while true; do
        if [ "$AUTOMATED" = "1" ]; then
            val="${current_val:-$default_val}"
        else
            read -rp "$prompt_text [$default_val]: " val
            val="${val:-$default_val}"
        fi
        if [[ "$val" =~ ^[0-9]+[GgMm]$ ]]; then
            echo "$val" | tr '[:lower:]' '[:upper:]'
            return 0
        fi
        [ "$AUTOMATED" = "1" ] && die "AUTOMATED mode: invalid heap size '$val' (use e.g. 8G or 4096M)."
        echo "  Use a number followed by G or M (e.g. 8G)." >&2
    done
}

heap_to_mb() {
    local v="$1" n="${1%[GgMm]}" u="${1: -1}"
    case "$u" in
        G|g) echo $((n * 1024)) ;;
        *)   echo "$n" ;;
    esac
}

fmt_size() {
    local mb="$1"
    if [ $((mb % 1024)) -eq 0 ]; then echo "$((mb / 1024))GB"; else echo "${mb}MB"; fi
}

# ---------- OS service user ----------
ensure_service_user() {
    local svc_user="$1" home_dir="$2"
    if [ "$svc_user" = "root" ]; then
        warn "SERVICE_USER=root - Trino will run as root. This matches the original manual steps but is NOT recommended for production; consider SERVICE_USER=trino."
        return 0
    fi
    if id "$svc_user" >/dev/null 2>&1; then
        ok "OS user '$svc_user' already exists."
    else
        log "Creating OS user '$svc_user' (no login shell, system account)..."
        useradd --system --home-dir "$home_dir" --shell /usr/sbin/nologin "$svc_user" \
            || die "Failed to create OS user $svc_user"
        ok "OS user '$svc_user' created."
    fi
}

# ---------- download helper with fallback URLs + gzip validation ----------
download_file() {
    local dest="$1"; shift
    local url
    for url in "$@"; do
        log "Downloading $url ..."
        # -L/redirects are followed by wget by default (Maven Central now 301-redirects to GitHub)
        if wget -q --show-progress --tries=3 --timeout=60 -c "$url" -O "$dest"; then
            [ -s "$dest" ] && return 0
        fi
        warn "Download failed from $url"
        rm -f "$dest"
    done
    return 1
}

# is_valid_cli <file> : accepts the self-executing CLI (starts with '#!') or a plain jar (zip, 'PK')
is_valid_cli() {
    local f="$1" magic
    [ -s "$f" ] || return 1
    magic="$(head -c 2 "$f" 2>/dev/null)"
    [ "$magic" = "#!" ] || [ "$magic" = "PK" ]
}

# java_major_for_trino <version> : Trino >= 479 needs Java 25, older (470-478) Java 24
java_major_for_trino() {
    local v="${1%%.*}"
    if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 479 ]; then echo 25; else echo 24; fi
}

# fetch_tgz <dest> <url...> : reuse a valid cached tarball, otherwise (re)download it
fetch_tgz() {
    local dest="$1"; shift
    if [ -s "$dest" ] && gzip -t "$dest" >/dev/null 2>&1; then
        ok "Using cached archive: $dest"
        return 0
    fi
    [ -e "$dest" ] && { warn "Cached archive $dest is incomplete/corrupt - downloading again."; rm -f "$dest"; }
    download_file "$dest" "$@" || return 1
    gzip -t "$dest" >/dev/null 2>&1 || { rm -f "$dest"; return 1; }
    return 0
}

# ---------- Java (Temurin, side-by-side) ----------
java_major() {
    "$1/bin/java" -version 2>&1 | awk -F'"' '/version/ {split($2,a,"."); print a[1]; exit}'
}

find_java() {
    local req="$1" c major
    for c in "${JAVA_HOME:-}" \
             "/usr/lib/jvm/temurin-${req}-jdk" "/usr/lib/jvm/temurin-${req}-jdk-amd64" \
             "/usr/lib/jvm/java-${req}-openjdk-amd64" /usr/lib/jvm/jdk-"${req}"*; do
        [ -n "$c" ] && [ -x "$c/bin/java" ] || continue
        major="$(java_major "$c")"
        if [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge "$req" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

install_temurin() {
    local req="$1" target="/usr/lib/jvm/temurin-${1}-jdk" arch url tarball
    case "$(uname -m)" in
        x86_64|amd64)  arch="x64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) die "Unsupported CPU architecture '$(uname -m)' for automatic Java install. Install JDK ${req} manually and export JAVA_HOME." ;;
    esac
    url="${JAVA_TARBALL_URL:-https://api.adoptium.net/v3/binary/latest/${req}/ga/linux/${arch}/jdk/hotspot/normal/eclipse}"
    tarball="${SOURCE_DIR}/temurin-${req}-jdk-${arch}.tar.gz"

    log "Installing Temurin JDK ${req} into ${target} (system Java is left untouched) ..."
    fetch_tgz "$tarball" "$url" || die "Could not download JDK ${req} from $url. Set JAVA_TARBALL_URL to a reachable mirror, or install JDK ${req} manually and export JAVA_HOME."
    mkdir -p "$target"
    tar -xzf "$tarball" -C "$target" --strip-components=1 >> "$LOG_FILE" 2>&1 \
        || die "Extracting the JDK failed. See $LOG_FILE"
    [ -x "$target/bin/java" ] || die "JDK extracted but $target/bin/java is missing."
}

ensure_java() {
    local req="$1"
    JAVA_HOME_DETECTED="$(find_java "$req" || true)"
    if [ -z "$JAVA_HOME_DETECTED" ]; then
        install_temurin "$req"
        JAVA_HOME_DETECTED="$(find_java "$req" || true)"
        [ -n "$JAVA_HOME_DETECTED" ] || die "Java ${req}+ still not found after installation."
    fi
    ok "Using JAVA_HOME=${JAVA_HOME_DETECTED} ($("${JAVA_HOME_DETECTED}/bin/java" -version 2>&1 | head -n1))"
}

# ---------- Trino server ----------
installed_trino_version() {
    local f
    f="$(ls "$1"/lib/trino-main-*.jar 2>/dev/null | head -n1)"
    [ -n "$f" ] || return 1
    f="$(basename "$f")"; f="${f#trino-main-}"; echo "${f%.jar}"
}

install_trino() {
    local version="$1" home="$2" have tarball src
    have="$(installed_trino_version "$home" || true)"
    if [ -n "$have" ]; then
        if [ "$have" = "$version" ]; then
            ok "Trino ${version} already present in ${home} - skipping download/copy."
            return 0
        fi
        die "${home} already contains Trino ${have}, requested ${version}. Upgrades must go into a clean directory (stale jars in lib/ and plugin/ break Trino). Use a new TRINO_HOME or remove lib/ and plugin/ first."
    fi

    tarball="${SOURCE_DIR}/trino-server-${version}.tar.gz"
    fetch_tgz "$tarball" \
        "https://repo1.maven.org/maven2/io/trino/trino-server/${version}/trino-server-${version}.tar.gz" \
        "https://github.com/trinodb/trino/releases/download/${version}/trino-server-${version}.tar.gz" \
        || die "Could not download trino-server-${version}. Not every release is published (Trino 470-476 tarballs are no longer downloadable; use 477 or newer), or there is no network access. Check TRINO_VERSION."

    log "Extracting trino-server-${version} (large archive, please wait) ..."
    tar -xzf "$tarball" -C "$SOURCE_DIR" >> "$LOG_FILE" 2>&1 || die "Extraction failed. See $LOG_FILE"
    src="${SOURCE_DIR}/trino-server-${version}"
    [ -x "${src}/bin/launcher" ] || die "Extracted directory ${src} has no bin/launcher - unexpected archive layout."

    log "Copying Trino into ${home} ..."
    cp -a "${src}/." "${home}/" || die "Copy into ${home} failed."
    [ -x "${home}/bin/launcher" ] || die "${home}/bin/launcher missing after copy."
    ok "Trino ${version} installed to ${home}"
}

# ---------- file writing helpers ----------
backup_file() {
    local f="$1"
    if [ -f "$f" ] && [ ! -f "${f}.bkp" ]; then
        cp -p "$f" "${f}.bkp"
    fi
}

# write_secure <file> : content on stdin, mode 600, previous version kept once as .bkp
write_secure() {
    local f="$1"
    backup_file "$f"
    cat > "$f"
    chmod 600 "$f"
}

# ---------- TLS keystore ----------
generate_keystore() {
    local ks="$1" ks_pass="$2" host="$3" san
    if [ -f "$ks" ]; then
        ok "Keystore already exists at ${ks} - keeping it."
        return 0
    fi
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        san="ip:${host},dns:localhost,ip:127.0.0.1"
    else
        san="dns:${host},dns:localhost,ip:127.0.0.1"
    fi
    log "Generating PKCS12 keystore ${ks} (CN=${host}, valid ${CERT_VALIDITY_DAYS} days) ..."
    "${JAVA_HOME_DETECTED}/bin/keytool" -genkeypair \
        -alias trino -keyalg RSA -keysize 2048 \
        -storetype PKCS12 -keystore "$ks" -storepass "$ks_pass" \
        -validity "$CERT_VALIDITY_DAYS" \
        -dname "CN=${host}, OU=Data, O=Trino, C=IN" \
        -ext "SAN=${san}" >> "$LOG_FILE" 2>&1 \
        || die "keytool failed to create the keystore. See $LOG_FILE"
    chmod 600 "$ks"
    ok "Keystore created (self-signed)."
}

import_cert_to_jvm() {
    local ks="$1" ks_pass="$2" host="$3"
    local cacerts="${JAVA_HOME_DETECTED}/lib/security/cacerts"
    local kt="${JAVA_HOME_DETECTED}/bin/keytool"
    local alias="trino-${host}" pem
    [ -f "$cacerts" ] || { warn "cacerts not found at ${cacerts} - skipping certificate import."; return 0; }
    if "$kt" -list -keystore "$cacerts" -storepass changeit -alias "$alias" >/dev/null 2>&1; then
        ok "Certificate alias '${alias}' already trusted by the JVM."
        return 0
    fi
    pem="$(mktemp)"
    "$kt" -exportcert -rfc -alias trino -keystore "$ks" -storepass "$ks_pass" -file "$pem" >> "$LOG_FILE" 2>&1 \
        || { rm -f "$pem"; warn "Could not export the certificate - skipping JVM trust import."; return 0; }
    if "$kt" -importcert -noprompt -trustcacerts -alias "$alias" -file "$pem" \
            -keystore "$cacerts" -storepass changeit >> "$LOG_FILE" 2>&1; then
        ok "Certificate imported into ${cacerts} (alias ${alias})."
    else
        warn "Could not import the certificate into ${cacerts} (non-default cacerts password?). Trino may fail to talk to itself over HTTPS - see the log."
    fi
    rm -f "$pem"
}

# ---------- Trino configuration ----------
write_trino_config() {
    log "Writing Trino configuration under ${ETC_DIR} ..."

    write_secure "${ETC_DIR}/config.properties" <<EOF
coordinator=true
node-scheduler.include-coordinator=true
http-server.http.enabled=false
http-server.https.enabled=true
http-server.https.port=${HTTPS_PORT}
http-server.https.keystore.path=${KEYSTORE_PATH}
http-server.https.keystore.key=${KEYSTORE_PASSWORD}
query.max-memory=${QUERY_MAX_MEMORY}
query.max-memory-per-node=${QUERY_MAX_MEMORY_PER_NODE}
query.max-length=5000000

discovery.uri=https://${TRINO_HOST}:${HTTPS_PORT}

$( [ "$ENABLE_PASSWORD_AUTH" = "1" ] && echo "http-server.authentication.type=PASSWORD" )
internal-communication.shared-secret=${SHARED_SECRET}
internal-communication.https.required=true

log.path=${LOG_DIR}/server.log
http-server.log.path=${LOG_DIR}/http-request.log
web-ui.session-timeout=1h
EOF

    write_secure "${ETC_DIR}/jvm.config" <<EOF
-server
-Xms${HEAP_SIZE}
-Xmx${HEAP_SIZE}

-XX:+UseG1GC
-XX:+ParallelRefProcEnabled
-XX:InitiatingHeapOccupancyPercent=35
-XX:+UseStringDeduplication

-Xlog:gc*:file=${LOG_DIR}/gc.log:time,uptime,level,tags

-XX:+AlwaysPreTouch
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=${LOG_DIR}/heapdump.hprof

-Xss256k
-XX:+TieredCompilation
$( [ "${REQUIRED_JAVA_MAJOR:-24}" -ge 25 ] && echo "--add-modules=jdk.incubator.vector" )
EOF
    chmod 644 "${ETC_DIR}/jvm.config"

    write_secure "${ETC_DIR}/node.properties" <<EOF
node.environment=${NODE_ENVIRONMENT}
node.id=${NODE_ID}
node.data-dir=${DATA_DIR}
EOF
    chmod 644 "${ETC_DIR}/node.properties"
    ok "config.properties, jvm.config, node.properties written."
}

setup_password_auth() {
    local pw_file="$1" user="$2" pass="$3"
    log "Configuring PASSWORD authentication (file authenticator, bcrypt) ..."
    write_secure "${ETC_DIR}/password-authenticator.properties" <<EOF
password-authenticator.name=file
file.password-file=${pw_file}
EOF
    if [ -f "$pw_file" ]; then
        backup_file "$pw_file"
        printf '%s' "$pass" | htpasswd -B -C 10 -i "$pw_file" "$user" >> "$LOG_FILE" 2>&1 \
            || die "htpasswd failed to update ${pw_file}. See $LOG_FILE"
    else
        printf '%s' "$pass" | htpasswd -B -C 10 -i -c "$pw_file" "$user" >> "$LOG_FILE" 2>&1 \
            || die "htpasswd failed to create ${pw_file}. See $LOG_FILE"
    fi
    chmod 600 "$pw_file"
    ok "User '${user}' set in ${pw_file}."
}

# ---------- catalogs ----------
write_catalog_pg() {
    write_secure "${CATALOG_DIR}/${PG_CATALOG_NAME}.properties" <<EOF
connector.name=postgresql
connection-url=jdbc:postgresql://${PG_HOST}:${PG_PORT}/${PG_DB}
connection-user=${PG_USER}
connection-password=${PG_PASSWORD}
EOF
    ok "Catalog '${PG_CATALOG_NAME}' (PostgreSQL ${PG_HOST}:${PG_PORT}/${PG_DB}) written."
}

write_catalog_iceberg_azure() {
    write_secure "${CATALOG_DIR}/iceberg.properties" <<EOF
connector.name=iceberg

iceberg.catalog.type=jdbc

iceberg.jdbc-catalog.connection-url=jdbc:postgresql://${PG_HOST}:${PG_PORT}/${PG_DB}
iceberg.jdbc-catalog.connection-user=${PG_USER}
iceberg.jdbc-catalog.connection-password=${PG_PASSWORD}
iceberg.jdbc-catalog.catalog-name=${ICEBERG_JDBC_CATALOG_NAME}
iceberg.jdbc-catalog.driver-class=org.postgresql.Driver

iceberg.jdbc-catalog.default-warehouse-dir=abfs://${AZURE_CONTAINER}@${AZURE_STORAGE_ACCOUNT}.dfs.core.windows.net/${AZURE_WAREHOUSE_PATH}

fs.native-azure.enabled=true
azure.auth-type=ACCESS_KEY
azure.access-key=${AZURE_ACCESS_KEY}
azure.endpoint=core.windows.net

iceberg.file-format=PARQUET
iceberg.compression-codec=GZIP
EOF
    ok "Catalog 'iceberg' (JDBC ${PG_HOST}:${PG_PORT}/${PG_DB}, ADLS ${AZURE_STORAGE_ACCOUNT}/${AZURE_CONTAINER}) written."
}

write_catalog_nessie() {
    {
        echo "connector.name=iceberg"
        echo
        echo "iceberg.catalog.type=nessie"
        echo "iceberg.nessie-catalog.uri=${NESSIE_URI}"
        echo "iceberg.nessie-catalog.ref=${NESSIE_REF}"
        echo "iceberg.nessie-catalog.default-warehouse-dir=${NESSIE_WAREHOUSE}"
        echo
        echo "fs.native-s3.enabled=true"
        echo "s3.region=${AWS_REGION}"
        echo "s3.endpoint=https://s3.${AWS_REGION}.amazonaws.com"
        if [ -n "$AWS_ACCESS_KEY" ] && [ -n "$AWS_SECRET_KEY" ]; then
            echo "s3.aws-access-key=${AWS_ACCESS_KEY}"
            echo "s3.aws-secret-key=${AWS_SECRET_KEY}"
        fi
        echo
        echo "iceberg.file-format=PARQUET"
        echo "iceberg.compression-codec=GZIP"
    } | write_secure "${CATALOG_DIR}/nessie.properties"
    ok "Catalog 'nessie' (${NESSIE_URI}, warehouse ${NESSIE_WAREHOUSE}) written."
}

write_catalog_druid() {
    write_secure "${CATALOG_DIR}/druid.properties" <<EOF
connector.name=druid
connection-url=jdbc:avatica:remote:url=http://${DRUID_HOST}:${DRUID_PORT}/druid/v2/sql/avatica/;authentication=BASIC
connection-user=${DRUID_USER}
connection-password=${DRUID_PASSWORD}
EOF
    ok "Catalog 'druid' (${DRUID_HOST}:${DRUID_PORT}) written."
}

# ---------- Trino CLI ----------
install_cli() {
    local version="$1" home="$2"
    CLI_JAR="${home}/trino-cli-${version}-executable.jar"
    CLI_WRAPPER="/usr/local/bin/trino"
    if [ -s "$CLI_JAR" ] && ! is_valid_cli "$CLI_JAR"; then
        warn "Existing $CLI_JAR is not a valid CLI - downloading again."
        rm -f "$CLI_JAR"
    fi
    if [ ! -s "$CLI_JAR" ]; then
        # Newer releases publish the CLI on GitHub as 'trino-cli-<ver>' (no -executable.jar suffix);
        # older ones live on Maven Central as 'trino-cli-<ver>-executable.jar'.
        download_file "$CLI_JAR" \
            "https://github.com/trinodb/trino/releases/download/${version}/trino-cli-${version}" \
            "https://repo1.maven.org/maven2/io/trino/trino-cli/${version}/trino-cli-${version}-executable.jar" \
            || die "Could not download trino-cli ${version}."
        is_valid_cli "$CLI_JAR" || { rm -f "$CLI_JAR"; die "Downloaded trino-cli ${version} is not a valid jar/executable."; }
    else
        ok "Trino CLI already present: ${CLI_JAR}"
    fi
    chmod 755 "$CLI_JAR"
    cat > "$CLI_WRAPPER" <<EOF
#!/bin/bash
# Generated by trino_install.sh - runs the Trino CLI with the Java it was installed for
exec "${JAVA_HOME_DETECTED}/bin/java" --enable-native-access=ALL-UNNAMED -jar "${CLI_JAR}" "\$@"
EOF
    chmod 755 "$CLI_WRAPPER"
    ok "Trino CLI installed; wrapper at ${CLI_WRAPPER} (run: trino --server https://${TRINO_HOST}:${HTTPS_PORT} --insecure ...)"
}

# ---------- systemd ----------
create_service_unit() {
    local name="$1" svc_user="$2" home="$3" java_home="$4"
    local unit_file="/etc/systemd/system/${name}.service"

    log "Creating systemd unit: $unit_file"
    cat > "$unit_file" <<EOF
[Unit]
Description=Trino Query Engine
After=network-online.target
Wants=network-online.target

[Service]
User=${svc_user}
Group=${svc_user}
WorkingDirectory=${home}

Environment="JAVA_HOME=${java_home}"
Environment="PATH=${java_home}/bin:/usr/bin:/bin"

Type=simple
ExecStart=${home}/bin/launcher run

Restart=on-failure
RestartSec=5
TimeoutStartSec=120
TimeoutStopSec=60

LimitNOFILE=131072
TasksMax=infinity

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${name}.service" >> "$LOG_FILE" 2>&1
    ok "systemd service '${name}' created and enabled."
}

# ---------- readiness ----------
wait_for_port() {
    local host="$1" port="$2" tries="${3:-30}"
    while [ "$tries" -gt 0 ]; do
        if (echo > "/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        tries=$((tries - 1))
    done
    return 1
}

trino_info() {
    local url="https://127.0.0.1:${HTTPS_PORT}/v1/info" u p
    if [ "$ENABLE_PASSWORD_AUTH" = "1" ]; then
        u="${ADMIN_USERNAME//\\/\\\\}"; u="${u//\"/\\\"}"
        p="${ADMIN_PASSWORD//\\/\\\\}"; p="${p//\"/\\\"}"
        printf 'user = "%s:%s"\n' "$u" "$p" | curl -sk --max-time 5 -K - "$url"
    else
        curl -sk --max-time 5 "$url"
    fi
}

wait_for_trino_ready() {
    local tries=90
    while [ "$tries" -gt 0 ]; do
        if trino_info 2>/dev/null | grep -q '"starting":false'; then
            return 0
        fi
        sleep 2
        tries=$((tries - 1))
    done
    return 1
}

print_banner() {
    echo
    echo "======================================================================"
    echo " $1"
    echo "======================================================================"
}

# ------------------------------------------------------------------
# 1. Interactive input (or env-var driven, see AUTOMATED above)
# ------------------------------------------------------------------
require_root
print_banner "Trino - Automated Installation"
[ "$AUTOMATED" = "1" ] && log "Running in AUTOMATED (non-interactive) mode."

CERT_VALIDITY_DAYS="${CERT_VALIDITY_DAYS:-3650}"
IMPORT_CERT_TO_JVM="${IMPORT_CERT_TO_JVM:-1}"

set_var TRINO_HOME   prompt_safe_dir "Trino install directory" "/opt/trino" "${TRINO_HOME:-}"
set_var SOURCE_DIR   prompt_safe_dir "Directory for downloaded archives" "/opt/ausiytic/softwares" "${SOURCE_DIR:-}"
set_var TRINO_VERSION prompt_nonempty "Trino server version" "483" "${TRINO_VERSION:-}"
set_var CLI_VERSION  prompt_nonempty "Trino CLI version" "$TRINO_VERSION" "${CLI_VERSION:-}"
REQUIRED_JAVA_MAJOR="${REQUIRED_JAVA_MAJOR:-$(java_major_for_trino "$TRINO_VERSION")}"
log "Trino ${TRINO_VERSION} requires Java ${REQUIRED_JAVA_MAJOR}+."
set_var SERVICE_USER prompt_nonempty "OS user to run Trino as (root matches original manual steps)" "root" "${SERVICE_USER:-}"

DEFAULT_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$DEFAULT_HOST" ] || DEFAULT_HOST="$(hostname -f 2>/dev/null || hostname)"
set_var TRINO_HOST   prompt_nonempty "Coordinator host/IP (used in discovery.uri and the certificate)" "$DEFAULT_HOST" "${TRINO_HOST:-}"
set_var HTTPS_PORT   prompt_port "Trino HTTPS port" "8443" "${HTTPS_PORT:-}"
set_var NODE_ENVIRONMENT prompt_nonempty "Trino node.environment" "development" "${NODE_ENVIRONMENT:-}"
set_var NODE_ID      prompt_nonempty "Trino node.id (unique per node)" "trino-coordinator" "${NODE_ID:-}"
set_var HEAP_SIZE    prompt_heap "JVM heap size (-Xms/-Xmx)" "8G" "${HEAP_SIZE:-}"
set_var KEYSTORE_PASSWORD prompt_secret "Keystore password (min 6 chars)" "${KEYSTORE_PASSWORD:-}" 6

set_var ENABLE_PASSWORD_AUTH prompt_yesno "Enable PASSWORD authentication (recommended)" "1" "${ENABLE_PASSWORD_AUTH:-}"
ADMIN_USERNAME="${ADMIN_USERNAME:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
if [ "$ENABLE_PASSWORD_AUTH" = "1" ]; then
    set_var ADMIN_USERNAME prompt_nonempty "Trino admin username" "admin" "$ADMIN_USERNAME"
    set_var ADMIN_PASSWORD prompt_secret "Trino admin password (min 8 chars)" "$ADMIN_PASSWORD" 8
fi

# ----- catalogs (all OFF by default) -----
set_var ENABLE_PG            prompt_yesno "Configure PostgreSQL catalog" "0" "${ENABLE_PG:-}"
set_var ENABLE_ICEBERG_AZURE prompt_yesno "Configure Iceberg catalog (JDBC in PostgreSQL + Azure ADLS Gen2 warehouse)" "0" "${ENABLE_ICEBERG_AZURE:-}"
set_var ENABLE_NESSIE        prompt_yesno "Configure Nessie catalog (S3 warehouse)" "0" "${ENABLE_NESSIE:-}"
set_var ENABLE_DRUID         prompt_yesno "Configure Druid catalog" "0" "${ENABLE_DRUID:-}"

PG_HOST="${PG_HOST:-}"; PG_PORT="${PG_PORT:-}"; PG_DB="${PG_DB:-}"; PG_USER="${PG_USER:-}"; PG_PASSWORD="${PG_PASSWORD:-}"
if [ "$ENABLE_PG" = "1" ] || [ "$ENABLE_ICEBERG_AZURE" = "1" ]; then
    set_var PG_HOST     prompt_nonempty "PostgreSQL host" "" "$PG_HOST"
    set_var PG_PORT     prompt_port "PostgreSQL port" "" "$PG_PORT"
    set_var PG_DB       prompt_nonempty "PostgreSQL database name" "" "$PG_DB"
    set_var PG_USER     prompt_nonempty "PostgreSQL user" "" "$PG_USER"
    set_var PG_PASSWORD prompt_secret "PostgreSQL password" "$PG_PASSWORD" 1
fi
PG_CATALOG_NAME="${PG_CATALOG_NAME:-}"
if [ "$ENABLE_PG" = "1" ]; then
    set_var PG_CATALOG_NAME prompt_nonempty "Trino catalog name for the PostgreSQL connector" "pg_${PG_DB}" "$PG_CATALOG_NAME"
fi

AZURE_STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT:-}"; AZURE_CONTAINER="${AZURE_CONTAINER:-}"; AZURE_ACCESS_KEY="${AZURE_ACCESS_KEY:-}"
AZURE_WAREHOUSE_PATH="${AZURE_WAREHOUSE_PATH:-}"; ICEBERG_JDBC_CATALOG_NAME="${ICEBERG_JDBC_CATALOG_NAME:-}"
if [ "$ENABLE_ICEBERG_AZURE" = "1" ]; then
    set_var AZURE_STORAGE_ACCOUNT prompt_nonempty "Azure storage account name" "" "$AZURE_STORAGE_ACCOUNT"
    set_var AZURE_CONTAINER       prompt_nonempty "Azure blob container (file system) name" "" "$AZURE_CONTAINER"
    set_var AZURE_WAREHOUSE_PATH  prompt_nonempty "Warehouse path inside the container" "warehouse" "$AZURE_WAREHOUSE_PATH"
    set_var AZURE_ACCESS_KEY      prompt_secret "Azure storage account access key" "$AZURE_ACCESS_KEY" 1
    set_var ICEBERG_JDBC_CATALOG_NAME prompt_nonempty "Iceberg JDBC catalog-name" "azure" "$ICEBERG_JDBC_CATALOG_NAME"
fi

NESSIE_URI="${NESSIE_URI:-}"; NESSIE_REF="${NESSIE_REF:-}"; NESSIE_WAREHOUSE="${NESSIE_WAREHOUSE:-}"
AWS_REGION="${AWS_REGION:-}"; AWS_ACCESS_KEY="${AWS_ACCESS_KEY:-}"; AWS_SECRET_KEY="${AWS_SECRET_KEY:-}"
if [ "$ENABLE_NESSIE" = "1" ]; then
    set_var NESSIE_URI       prompt_nonempty "Nessie API URI" "http://${TRINO_HOST}:19120/api/v1" "$NESSIE_URI"
    set_var NESSIE_REF       prompt_nonempty "Nessie reference (branch)" "main" "$NESSIE_REF"
    set_var NESSIE_WAREHOUSE prompt_nonempty "Nessie warehouse location (e.g. s3://bucket/warehouse)" "" "$NESSIE_WAREHOUSE"
    set_var AWS_REGION       prompt_nonempty "AWS region" "us-east-1" "$AWS_REGION"
    set_var AWS_ACCESS_KEY   prompt_secret "AWS access key id (Enter to use the instance role / default credential chain)" "$AWS_ACCESS_KEY" 1 1
    if [ -n "$AWS_ACCESS_KEY" ]; then
        set_var AWS_SECRET_KEY prompt_secret "AWS secret access key" "$AWS_SECRET_KEY" 1
    else
        AWS_SECRET_KEY=""
    fi
fi

DRUID_HOST="${DRUID_HOST:-}"; DRUID_PORT="${DRUID_PORT:-}"; DRUID_USER="${DRUID_USER:-}"; DRUID_PASSWORD="${DRUID_PASSWORD:-}"
if [ "$ENABLE_DRUID" = "1" ]; then
    set_var DRUID_HOST     prompt_nonempty "Druid router host" "" "$DRUID_HOST"
    set_var DRUID_PORT     prompt_port "Druid router port" "8082" "$DRUID_PORT"
    set_var DRUID_USER     prompt_nonempty "Druid user" "admin" "$DRUID_USER"
    set_var DRUID_PASSWORD prompt_secret "Druid password" "$DRUID_PASSWORD" 1
fi

# ------------------------------------------------------------------
# 2. Derived values
# ------------------------------------------------------------------
[ -n "$TRINO_HOME" ] || die "TRINO_HOME is empty - refusing to continue."
ETC_DIR="${TRINO_HOME}/etc"
CATALOG_DIR="${ETC_DIR}/catalog"
LOG_DIR="${TRINO_HOME}/logs"
DATA_DIR="${TRINO_HOME}/data"
KEYSTORE_PATH="${ETC_DIR}/coordinator.p12"
PASSWORD_FILE="${ETC_DIR}/password.db"
SERVICE_NAME="trino"
SUMMARY_FILE="${TRINO_HOME}/trino_install_summary.txt"

SHARED_SECRET="${SHARED_SECRET:-$(openssl rand -hex 32 2>/dev/null)}"
[ -n "$SHARED_SECRET" ] || die "Could not generate SHARED_SECRET (is openssl installed?). Export SHARED_SECRET and re-run."

HEAP_MB="$(heap_to_mb "$HEAP_SIZE")"
QUERY_MAX_MEMORY_PER_NODE="${QUERY_MAX_MEMORY_PER_NODE:-$(fmt_size $((HEAP_MB / 2)))}"
QUERY_MAX_MEMORY="${QUERY_MAX_MEMORY:-$(fmt_size $((HEAP_MB * 3 / 4)))}"

MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
if [ "${MEM_MB:-0}" -gt 0 ] && [ "$HEAP_MB" -gt $((MEM_MB * 80 / 100)) ]; then
    warn "Heap ${HEAP_SIZE} is more than 80% of this machine's RAM (${MEM_MB} MB). With -XX:+AlwaysPreTouch Trino may fail to start or the OS may kill it - consider a smaller HEAP_SIZE."
fi

# ------------------------------------------------------------------
# 3. OS + dependencies
# ------------------------------------------------------------------
detect_os
install_deps

# ------------------------------------------------------------------
# 4. Directories, service user, Java
# ------------------------------------------------------------------
log "Creating directory structure ..."
mkdir -p "$SOURCE_DIR" "$TRINO_HOME" "$ETC_DIR" "$CATALOG_DIR" "$LOG_DIR" "$DATA_DIR"
ensure_service_user "$SERVICE_USER" "$TRINO_HOME"
ensure_java "$REQUIRED_JAVA_MAJOR"

# ------------------------------------------------------------------
# 5. Trino server + CLI
# ------------------------------------------------------------------
install_trino "$TRINO_VERSION" "$TRINO_HOME"
install_cli "$CLI_VERSION" "$TRINO_HOME"

# ------------------------------------------------------------------
# 6. TLS + configuration + authentication + catalogs
# ------------------------------------------------------------------
generate_keystore "$KEYSTORE_PATH" "$KEYSTORE_PASSWORD" "$TRINO_HOST"
if [ "$IMPORT_CERT_TO_JVM" = "1" ]; then
    import_cert_to_jvm "$KEYSTORE_PATH" "$KEYSTORE_PASSWORD" "$TRINO_HOST"
fi

write_trino_config

if [ "$ENABLE_PASSWORD_AUTH" = "1" ]; then
    setup_password_auth "$PASSWORD_FILE" "$ADMIN_USERNAME" "$ADMIN_PASSWORD"
else
    warn "PASSWORD authentication disabled - anyone who can reach https://${TRINO_HOST}:${HTTPS_PORT} can run queries."
fi

CATALOGS_WRITTEN=""
if [ "$ENABLE_PG" = "1" ];            then write_catalog_pg;            CATALOGS_WRITTEN="${CATALOGS_WRITTEN} ${PG_CATALOG_NAME}"; fi
if [ "$ENABLE_ICEBERG_AZURE" = "1" ]; then write_catalog_iceberg_azure; CATALOGS_WRITTEN="${CATALOGS_WRITTEN} iceberg"; fi
if [ "$ENABLE_NESSIE" = "1" ];        then write_catalog_nessie;        CATALOGS_WRITTEN="${CATALOGS_WRITTEN} nessie"; fi
if [ "$ENABLE_DRUID" = "1" ];         then write_catalog_druid;         CATALOGS_WRITTEN="${CATALOGS_WRITTEN} druid"; fi
[ -n "$CATALOGS_WRITTEN" ] || warn "No catalogs enabled - Trino will start with only the built-in system catalog."

# ------------------------------------------------------------------
# 7. Ownership / permissions
# ------------------------------------------------------------------
chmod 750 "$ETC_DIR" "$CATALOG_DIR"
if [ "$SERVICE_USER" != "root" ]; then
    chown -R "$SERVICE_USER":"$SERVICE_USER" "$TRINO_HOME"
fi
ok "Ownership and permissions applied."

# ------------------------------------------------------------------
# 8. systemd service + start
# ------------------------------------------------------------------
create_service_unit "$SERVICE_NAME" "$SERVICE_USER" "$TRINO_HOME" "$JAVA_HOME_DETECTED"

log "Starting ${SERVICE_NAME}.service ..."
systemctl restart "${SERVICE_NAME}.service" \
    || die "Failed to start ${SERVICE_NAME}.service - check 'journalctl -u ${SERVICE_NAME}' and ${LOG_DIR}/server.log"

if ! systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    die "${SERVICE_NAME}.service is not active - check 'journalctl -u ${SERVICE_NAME}' and ${LOG_DIR}/server.log"
fi

log "Waiting for Trino to finish starting (up to ~3 minutes) ..."
if ! wait_for_port "127.0.0.1" "$HTTPS_PORT" 60; then
    die "Trino did not open port ${HTTPS_PORT}. Check 'journalctl -u ${SERVICE_NAME}' and ${LOG_DIR}/server.log."
fi
if wait_for_trino_ready; then
    ok "Trino is up and ready on https://${TRINO_HOST}:${HTTPS_PORT}"
else
    die "Port ${HTTPS_PORT} is open but Trino never reported ready (/v1/info). Check ${LOG_DIR}/server.log (common causes: TLS trust, bad catalog credentials)."
fi

# Smoke test through the CLI (also validates authentication + TLS)
log "Running smoke test: SHOW CATALOGS ..."
if [ "$ENABLE_PASSWORD_AUTH" = "1" ]; then
    SMOKE_OUT="$(TRINO_PASSWORD="$ADMIN_PASSWORD" timeout 120 "$CLI_WRAPPER" --server "https://127.0.0.1:${HTTPS_PORT}" --insecure --user "$ADMIN_USERNAME" --password --execute "SHOW CATALOGS" </dev/null 2>&1)"
else
    SMOKE_OUT="$(timeout 120 "$CLI_WRAPPER" --server "https://127.0.0.1:${HTTPS_PORT}" --insecure --user trino_install --execute "SHOW CATALOGS" </dev/null 2>&1)"
fi
SMOKE_RC=$?
echo "$SMOKE_OUT" | tee -a "$LOG_FILE"
if [ "$SMOKE_RC" -eq 0 ]; then
    ok "Smoke test passed."
else
    warn "Smoke test failed (exit ${SMOKE_RC}). Trino is up, so check the credentials and ${LOG_DIR}/server.log."
fi

# ------------------------------------------------------------------
# 9. Summary
# ------------------------------------------------------------------
{
    echo "====================================================================="
    echo " Trino ${TRINO_VERSION} - single-node install summary"
    echo " Generated: $(date +'%F %T')"
    echo "====================================================================="
    echo "Trino home               : ${TRINO_HOME}"
    echo "Config dir               : ${ETC_DIR} (originals kept as *.bkp)"
    echo "Logs                     : ${LOG_DIR}"
    echo "JAVA_HOME                : ${JAVA_HOME_DETECTED}"
    echo "OS service user          : ${SERVICE_USER}"
    echo "Systemd service          : ${SERVICE_NAME}"
    echo "Web UI                   : https://${TRINO_HOST}:${HTTPS_PORT}/ui/"
    if [ "$ENABLE_PASSWORD_AUTH" = "1" ]; then
        echo "Authentication           : PASSWORD (user '${ADMIN_USERNAME}', password file ${PASSWORD_FILE}; password not written here)"
    else
        echo "Authentication           : NONE"
    fi
    echo "Keystore                 : ${KEYSTORE_PATH} (password only in config.properties)"
    echo "Heap / query memory      : ${HEAP_SIZE} / ${QUERY_MAX_MEMORY} total, ${QUERY_MAX_MEMORY_PER_NODE} per node"
    echo "Catalogs configured      :${CATALOGS_WRITTEN:- (none)}"
    echo "CLI                      : trino --server https://${TRINO_HOST}:${HTTPS_PORT} --insecure --user ${ADMIN_USERNAME:-<user>} --password"
    echo "====================================================================="
} | tee "$SUMMARY_FILE"
[ "$SERVICE_USER" != "root" ] && chown "$SERVICE_USER":"$SERVICE_USER" "$SUMMARY_FILE"
chmod 600 "$SUMMARY_FILE"

print_banner "TRINO INSTALLATION COMPLETE"
echo "(Summary saved to: $SUMMARY_FILE - passwords intentionally omitted)"
echo "Full install log: $LOG_FILE"
__TRINO_INSTALLER_EOF__
    chmod 700 "$dest"
    log_info "Trino installer written to $dest"
}

#########################################################

trino_run_installer() {
    local env_file rc SUDO=""
    [ "$(id -u)" -eq 0 ] || SUDO="sudo"

    trino_write_installer "$TRINO_INSTALLER" || return 1

    env_file=$(mktemp "$METHODS_DIR/.trino_env.XXXXXX") || { trino_fail "Cannot create temp env file"; return 1; }
    chmod 600 "$env_file"
    if ! trino_build_env_file "$env_file"; then
        rm -f "$env_file"
        return 1
    fi

    log_info "Running Trino installer as root (full output below and in $METHODS_DIR/trino_install.*.log)"
    # Installer output goes to stdout/stderr (so deploy_all.sh's log has it) AND the access log.
    $SUDO bash -c '. "$1"; exec bash "$2"' _ "$env_file" "$TRINO_INSTALLER" 2>&1 </dev/null | tee -a "$ACCESS_LOG"
    rc=${PIPESTATUS[0]}
    rm -f "$env_file"

    if [ "$rc" -ne 0 ]; then
        trino_fail "Trino installer exited with code $rc -- see $ACCESS_LOG and $METHODS_DIR/trino_install.*.log"
        return 1
    fi
    log_info "Trino installer finished successfully"
}

#########################################################

trino_verify_service() {
    local port
    port=$(trino_svc '.config.https_port // 8443')
    if ! systemctl is-active --quiet trino.service; then
        trino_fail "trino.service is not active -- check: journalctl -u trino, ${TRINO_HOME}/logs/server.log"
        return 1
    fi
    if ! (echo > "/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1; then
        trino_fail "trino.service is active but port ${port} is not accepting connections"
        return 1
    fi
    log_info "trino.service is active and listening on https port ${port}"
}

#########################################################

trino_install() {
    trino_init_vars || return 1
    trino_run_installer || return 1
    trino_verify_service || return 1
    log_info "Trino installation completed successfully"
    echo "Trino is up: https://${CURRENT_HOST}:$(trino_svc '.config.https_port // 8443')/ui/  (service: trino, home: ${TRINO_HOME})"
    return 0
}
