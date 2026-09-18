#!/usr/bin/env bash
# ============================================================================
# adsb-node-bootstrap v1.0.0
# One-command ADS-B feeder node setup for Ubuntu 24.04 / 26.04
# https://github.com/hank19CH/adsb-node-bootstrap
# MIT License
#
# Tested on: Ubuntu Server 26.04 LTS (arm64) — Raspberry Pi 4B / 5
#            Ubuntu Server 24.04 LTS (arm64/x86_64)
#
# Key fixes baked in:
#   - GCC 15 / Ubuntu 26.04 -Werror compile failures in the adsb.fi and
#     ADS-B Exchange feed clients (-Wunterminated-string-initialization)
#   - Fully unattended feeder setup: the four readsb-based feeders
#     (adsb.lol, adsb.fi, ADSBx, airplanes.live) are configured by
#     pre-seeding /etc/default/<feed> and calling their update.sh directly,
#     bypassing the whiptail configure.sh entirely
#   - OpenSky dpkg infinite prompt loop (correct openskyd/* debconf preseed)
#   - Missing Boost/zstd deps for dump978-fa
# ============================================================================
set -euo pipefail

VERSION="1.0.0"

# ═══════════════════════════════════════════════════════════════════
# Defaults (overridden by config.env or environment variables)
# ═══════════════════════════════════════════════════════════════════
LATITUDE="${LATITUDE:-}"
LONGITUDE="${LONGITUDE:-}"
ALTITUDE_FT="${ALTITUDE_FT:-}"
ALTITUDE_M="${ALTITUDE_M:-}"
FEED_ADSBLOL="${FEED_ADSBLOL:-yes}"
FEED_FLIGHTAWARE="${FEED_FLIGHTAWARE:-yes}"
FEED_ADSBFI="${FEED_ADSBFI:-yes}"
FEED_ADSBX="${FEED_ADSBX:-yes}"
FEED_AIRPLANESLIVE="${FEED_AIRPLANESLIVE:-yes}"
FEED_OPENSKY="${FEED_OPENSKY:-no}"
FEED_FR24="${FEED_FR24:-no}"
ENABLE_MLAT="${ENABLE_MLAT:-yes}"
MLAT_SITE_NAME="${MLAT_SITE_NAME:-}"
OPENSKY_USERNAME="${OPENSKY_USERNAME:-}"
ENABLE_UAT="${ENABLE_UAT:-no}"
NODE_USER="${NODE_USER:-adsb}"
NODE_HOSTNAME="${NODE_HOSTNAME:-}"
TIMEZONE="${TIMEZONE:-}"
SDR_SERIAL_1090="${SDR_SERIAL_1090:-}"
SDR_SERIAL_978="${SDR_SERIAL_978:-}"
READSB_GAIN="${READSB_GAIN:--10}"
BEAST_BIND_PORT="${BEAST_BIND_PORT:-30005}"
SKIP_SYSTEM_UPDATE="${SKIP_SYSTEM_UPDATE:-no}"
FORCE_REINSTALL="${FORCE_REINSTALL:-no}"
LOG_FILE="${LOG_FILE:-/var/log/adsb-bootstrap.log}"
RESTORE_UUIDS="${RESTORE_UUIDS:-}"

# Feeder identities (from --restore-uuids / uuids.env) — see README "Reimaging"
ADSBLOL_UUID="${ADSBLOL_UUID:-}"
ADSBFI_UUID="${ADSBFI_UUID:-}"
ADSBX_UUID="${ADSBX_UUID:-}"
AIRPLANES_UUID="${AIRPLANES_UUID:-}"
FLIGHTAWARE_FEEDER_ID="${FLIGHTAWARE_FEEDER_ID:-}"
OPENSKY_SERIAL="${OPENSKY_SERIAL:-}"
FR24_KEY="${FR24_KEY:-}"
UUID_RE='^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$'

NON_INTERACTIVE=false
CONFIG_FILE=""

# ═══════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()    { echo -e "${GREEN}[adsb-bootstrap]${NC} $*"; }
warn()   { echo -e "${YELLOW}[adsb-bootstrap WARN]${NC} $*"; }
err()    { echo -e "${RED}[adsb-bootstrap ERROR]${NC} $*" >&2; }
banner() { echo -e "\n${CYAN}══════════════════════════════════════════${NC}"; echo -e "${CYAN} $*${NC}"; echo -e "${CYAN}══════════════════════════════════════════${NC}\n"; }

die() { err "$@"; exit 1; }

is_yes() { [[ "${1,,}" =~ ^(yes|y|true|1)$ ]]; }

check_root() {
    [[ $EUID -eq 0 ]] || die "Must run as root (use sudo)"
}

detect_arch() {
    ARCH="$(uname -m)"
    case "$ARCH" in
        aarch64|arm64) ARCH="arm64" ;;
        x86_64)        ARCH="x86_64" ;;
        armv7l)        ARCH="armhf" ;;
        *) die "Unsupported architecture: $ARCH" ;;
    esac
    log "Architecture: $ARCH"
}

detect_os() {
    [[ -f /etc/os-release ]] || die "Cannot detect OS — /etc/os-release not found"
    . /etc/os-release
    OS_ID="$ID"
    OS_VERSION="$VERSION_ID"
    log "OS: $PRETTY_NAME"
    if [[ "$OS_ID" != "ubuntu" ]]; then
        warn "Tested on Ubuntu 24.04/26.04. Your OS ($OS_ID) may work but is untested."
    fi
}

detect_gcc_version() {
    if command -v gcc &>/dev/null; then
        GCC_MAJOR="$(gcc -dumpversion | cut -d. -f1)"
        log "GCC version: $(gcc -dumpversion) (major: $GCC_MAJOR)"
    else
        GCC_MAJOR=0
    fi
}

# Convert feet to meters (integer)
ft_to_m() { echo $(( ($1 * 3048 + 5000) / 10000 )); }

# ═══════════════════════════════════════════════════════════════════
# GCC 15 -Werror fix
#
# GCC 15 (Ubuntu 26.04) enables -Wunterminated-string-initialization
# by default. The adsb.fi and ADS-B Exchange feed clients clone and
# compile their own readsb forks (adsbfi/readsb@dev and
# adsbexchange/readsb@master, both frozen at 2024-06) with -Werror in
# the Makefile, and three char arrays sized without a NUL slot make
# the build fatal:
#   interactive.c:126        char spinner[4] = "|/-\\";
#   uat2esnt/uat_decode.c    static char base40_alphabet[40] = "...";
#   ais_charset.c            char ais_charset[64] = "...";
#
# Upstream wiedehopf/readsb fixed this in 21d399de (2025-07), and the
# adsb.lol (wiedehopf/readsb@stale) and airplanes.live
# (airplanes-live/readsb@dev) feeders track a fixed tree. Fixes have
# been offered to the two stale forks: adsbfi/readsb#2 and
# ADSBexchange/readsb#13. FlightAware and OpenSky install pre-built
# binaries and are unaffected.
#
# Fix: cc/gcc/g++ wrappers that strip standalone -Werror from compiler
# args. Installed in PATH before feed scripts run, removed after.
# Preserves -Werror=<specific> flags (e.g. -Werror=format-security).
# ═══════════════════════════════════════════════════════════════════
WERROR_FIX_DIR="/tmp/adsb-werror-fix"
WERROR_FIX_ACTIVE=false

install_werror_fix() {
    [[ "$GCC_MAJOR" -ge 15 ]] || return 0

    log "GCC $GCC_MAJOR detected — installing -Werror compiler wrappers"
    mkdir -p "$WERROR_FIX_DIR"

    for compiler in cc gcc g++; do
        local real_path
        real_path="$(readlink -f "$(command -v "$compiler" 2>/dev/null)" 2>/dev/null || true)"
        [[ -z "$real_path" ]] && continue

        cat > "${WERROR_FIX_DIR}/${compiler}" <<WRAPPER
#!/bin/bash
# Strips standalone -Werror so feed-client readsb builds succeed on GCC 15+
# Preserves -Werror=<specific> flags
args=()
for arg in "\$@"; do
    [[ "\$arg" == "-Werror" ]] && continue
    args+=("\$arg")
done
exec "$real_path" "\${args[@]}"
WRAPPER
        chmod +x "${WERROR_FIX_DIR}/${compiler}"
    done

    export PATH="${WERROR_FIX_DIR}:${PATH}"
    WERROR_FIX_ACTIVE=true
    log "  Wrappers active at $WERROR_FIX_DIR"
}

remove_werror_fix() {
    if $WERROR_FIX_ACTIVE; then
        export PATH="${PATH//${WERROR_FIX_DIR}:/}"
        rm -rf "$WERROR_FIX_DIR"
        WERROR_FIX_ACTIVE=false
        log "-Werror wrappers removed"
    fi
}

# ═══════════════════════════════════════════════════════════════════
# Generic script runner for installers we can't pre-seed (FR24).
# Critical: download-then-run pattern. NEVER use curl|bash — it
# consumes stdin and makes interactive dialogs (whiptail) hang
# with no way to recover except killing the process.
# ═══════════════════════════════════════════════════════════════════
run_installer_script() {
    local url="$1"
    local name="$2"
    local tmpfile="/tmp/${name}-install.sh"

    log "Downloading $name installer..."
    if ! curl -fsSL -o "$tmpfile" "$url" 2>/dev/null; then
        warn "Could not download $name installer — skipping"
        return 1
    fi
    chmod +x "$tmpfile"

    if $NON_INTERACTIVE; then
        bash "$tmpfile" </dev/null 2>&1 || {
            warn "$name installer returned non-zero — may need manual config"
            return 0
        }
    else
        # Redirect stdin from /dev/tty so whiptail dialogs work
        bash "$tmpfile" </dev/tty 2>&1 || {
            warn "$name installer returned non-zero — may need manual config"
            return 0
        }
    fi
}

# ═══════════════════════════════════════════════════════════════════
# Feeder identity restore (reimaging)
#
# Every aggregator identifies a station by a UUID/key kept in a file
# on the node. Restore those before the feeders install and a
# reimaged machine carries on as the same station with its history.
# The four readsb feeders' create-uuid.sh reuse an existing valid
# <feed>-uuid file, so restore = write the file before update.sh.
# ═══════════════════════════════════════════════════════════════════
load_restore_uuids() {
    if [[ -z "$RESTORE_UUIDS" && -f /boot/firmware/adsb-uuids.env ]]; then
        RESTORE_UUIDS=/boot/firmware/adsb-uuids.env
    fi
    [[ -n "$RESTORE_UUIDS" ]] || return 0
    [[ -f "$RESTORE_UUIDS" ]] || die "--restore-uuids file not found: $RESTORE_UUIDS"
    banner "Restoring feeder identities from $RESTORE_UUIDS"
    # shellcheck disable=SC1090
    set -a; source "$RESTORE_UUIDS"; set +a
    for v in ADSBLOL_UUID ADSBFI_UUID ADSBX_UUID AIRPLANES_UUID FLIGHTAWARE_FEEDER_ID OPENSKY_SERIAL FR24_KEY; do
        [[ -n "${!v}" ]] && log "  $v: set"
    done
}

# restore_feeder_uuid <label> <uuid-file> <uuid> — no-op when uuid is empty
restore_feeder_uuid() {
    local label="$1" file="$2" uuid="$3"
    [[ -n "$uuid" ]] || return 0
    if [[ ! "$uuid" =~ $UUID_RE ]]; then
        warn "$label UUID is not a valid UUID — ignoring"
        return 0
    fi
    mkdir -p "$(dirname "$file")"
    echo "$uuid" > "$file"
    log "$label: restored identity → $file"
}

# Snapshot every identity into one uuids.env-format file for safekeeping
uuid_from_file() { [[ -f "$1" ]] && tr -d '[:space:]' < "$1" || true; }
capture_uuids() {
    local out=/etc/adsb-node-uuids.env
    cat > "$out" <<UUIDS
# Feeder identities for $(hostname) — captured $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Restore on a reimaged node with: bootstrap.sh --restore-uuids <this file>
# or copy it to the SD boot partition as adsb-uuids.env before first boot.
ADSBLOL_UUID="$(uuid_from_file /usr/local/share/adsblol/adsblol-uuid)"
ADSBFI_UUID="$(uuid_from_file /usr/local/share/adsbfi/adsbfi-uuid)"
ADSBX_UUID="$(uuid_from_file /usr/local/share/adsbexchange/adsbx-uuid)"
AIRPLANES_UUID="$(uuid_from_file /usr/local/share/airplanes/airplanes-uuid)"
FLIGHTAWARE_FEEDER_ID="$(piaware-config -show feeder-id 2>/dev/null || uuid_from_file /var/cache/piaware/feeder_id)"
OPENSKY_SERIAL="$(grep -hsi '^Serial=' /var/lib/openskyd/conf.d/*.conf 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')"
FR24_KEY="$(grep -s '^fr24key=' /etc/fr24feed.ini 2>/dev/null | cut -d= -f2- | tr -d '"[:space:]')"
UUIDS
    chmod 600 "$out"
    log "Feeder identities saved to $out — keep a copy off the node (FlightAware/OpenSky ids may fill in after first connect)"
}

# ═══════════════════════════════════════════════════════════════════
# Interactive prompts (skipped with --non-interactive or --config)
# ═══════════════════════════════════════════════════════════════════
prompt_config() {
    $NON_INTERACTIVE && return 0

    echo ""
    log "No config file provided — interactive setup."
    echo ""

    [[ -z "$LATITUDE" ]]    && read -rp "Receiver latitude (decimal, e.g. 32.8998): " LATITUDE
    [[ -z "$LONGITUDE" ]]   && read -rp "Receiver longitude (decimal, e.g. -97.0403): " LONGITUDE
    [[ -z "$ALTITUDE_FT" ]] && read -rp "Antenna altitude (feet MSL): " ALTITUDE_FT
    [[ -z "$MLAT_SITE_NAME" ]] && read -rp "MLAT site name shown on aggregator maps [$(hostname)]: " MLAT_SITE_NAME

    echo ""
    echo "Which aggregators should this node feed?"
    for var_name in FEED_ADSBLOL FEED_FLIGHTAWARE FEED_ADSBFI FEED_ADSBX FEED_AIRPLANESLIVE FEED_OPENSKY FEED_FR24; do
        local pretty="${var_name#FEED_}"
        pretty="${pretty,,}"
        local current="${!var_name}"
        read -rp "  Feed ${pretty}? [${current}]: " input
        # printf -v, not declare: declare inside a function creates a local
        [[ -n "$input" ]] && printf -v "$var_name" '%s' "$input"
    done
}

validate_config() {
    [[ -n "$LATITUDE" ]]    || die "LATITUDE is required"
    [[ -n "$LONGITUDE" ]]   || die "LONGITUDE is required"

    # Need at least one altitude format
    if [[ -z "$ALTITUDE_FT" ]] && [[ -z "$ALTITUDE_M" ]]; then
        die "ALTITUDE_FT or ALTITUDE_M is required"
    fi

    # Derive whichever is missing
    if [[ -n "$ALTITUDE_FT" ]] && [[ -z "$ALTITUDE_M" ]]; then
        ALTITUDE_M="$(ft_to_m "$ALTITUDE_FT")"
    elif [[ -n "$ALTITUDE_M" ]] && [[ -z "$ALTITUDE_FT" ]]; then
        ALTITUDE_FT=$(( ALTITUDE_M * 10000 / 3048 ))
    fi

    [[ "$LATITUDE" =~ ^-?[0-9]+\.?[0-9]*$ ]]    || die "LATITUDE must be a decimal number"
    [[ "$LONGITUDE" =~ ^-?[0-9]+\.?[0-9]*$ ]]   || die "LONGITUDE must be a decimal number"

    # MLAT site name: the feeders show it on their MLAT maps and sanitise
    # it to [A-Za-z0-9_- ]. Default to the hostname. "0" disables MLAT.
    [[ -n "$MLAT_SITE_NAME" ]] || MLAT_SITE_NAME="${NODE_HOSTNAME:-$(hostname)}"
    MLAT_SITE_NAME_SAFE="$(echo -n "$MLAT_SITE_NAME" | tr -c '[a-zA-Z0-9]_\- ' '_')"
    is_yes "$ENABLE_MLAT" || MLAT_SITE_NAME_SAFE="0"
}

# ═══════════════════════════════════════════════════════════════════
# System setup
# ═══════════════════════════════════════════════════════════════════
install_base_deps() {
    banner "Installing base dependencies"

    export DEBIAN_FRONTEND=noninteractive

    if ! is_yes "$SKIP_SYSTEM_UPDATE"; then
        apt-get update -qq
        apt-get upgrade -y -qq
    fi

    # librtlsdr-dev pulls in the runtime lib (librtlsdr0 on 22.04,
    # librtlsdr2 on 24.04+) so we don't name it and break on either.
    apt-get install -y -qq \
        build-essential \
        git \
        curl \
        wget \
        ca-certificates \
        gnupg \
        lsb-release \
        pkg-config \
        cmake \
        libusb-1.0-0-dev \
        librtlsdr-dev \
        rtl-sdr \
        libsoapysdr-dev \
        soapysdr-module-rtlsdr \
        libncurses-dev \
        zlib1g-dev \
        libzstd-dev \
        libboost-program-options-dev \
        libboost-regex-dev \
        libboost-filesystem-dev \
        debhelper \
        fakeroot \
        python3 \
        python3-dev \
        python3-venv \
        uuid-runtime \
        net-tools \
        socat \
        jq \
        lighttpd \
        unattended-upgrades \
        apt-listchanges

    # Enable unattended security upgrades
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APTCONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APTCONF

    log "Base dependencies installed"
}

# ═══════════════════════════════════════════════════════════════════
# RTL-SDR driver blacklist
# The kernel's DVB-T drivers grab the RTL-SDR USB device before
# librtlsdr can. Must be blacklisted or readsb can't open the dongle.
# ═══════════════════════════════════════════════════════════════════
setup_rtlsdr_blacklist() {
    banner "RTL-SDR driver blacklist"

    cat > /etc/modprobe.d/blacklist-rtlsdr.conf <<'BLACKLIST'
# Block kernel DVB/TV drivers that conflict with librtlsdr userspace
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2838
blacklist dvb_usb_rtl2832u
BLACKLIST

    # Unload if currently loaded (non-fatal)
    for mod in dvb_usb_rtl28xxu rtl2832 rtl2838 dvb_usb_rtl2832u; do
        modprobe -r "$mod" 2>/dev/null || true
    done

    log "RTL-SDR kernel driver blacklist installed"
}

set_system_identity() {
    if [[ -n "$NODE_HOSTNAME" ]]; then
        hostnamectl set-hostname "$NODE_HOSTNAME"
        log "Hostname set to $NODE_HOSTNAME"
    fi
    if [[ -n "$TIMEZONE" ]]; then
        timedatectl set-timezone "$TIMEZONE"
        log "Timezone set to $TIMEZONE"
    fi
    # MLAT needs accurate time
    timedatectl set-ntp true 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════
# readsb (1090ES ADS-B decoder)
# Uses wiedehopf's install script — the community standard.
# ═══════════════════════════════════════════════════════════════════
install_readsb() {
    banner "Installing readsb"

    if ! command -v readsb &>/dev/null; then
        curl -sL -o /tmp/readsb-install.sh \
            https://github.com/wiedehopf/adsb-scripts/raw/master/readsb-install.sh
        bash /tmp/readsb-install.sh
    else
        log "readsb already installed — skipping"
    fi

    # Configure readsb
    local receiver_opts="--device-type rtlsdr --gain ${READSB_GAIN} --ppm 0"
    if [[ -n "$SDR_SERIAL_1090" ]]; then
        receiver_opts+=" --device ${SDR_SERIAL_1090}"
    fi

    cat > /etc/default/readsb <<READSB
RECEIVER_OPTIONS="${receiver_opts}"
DECODER_OPTIONS="--max-range 360 --fix --cpr-focus 0"
NET_OPTIONS="--net --net-heartbeat 60 --net-ri-port 30001 --net-ro-port 30002 --net-sbs-port 30003 --net-bi-port 30004,30104 --net-bo-port ${BEAST_BIND_PORT} --net-beast-reduce-out-port 30006"
JSON_OPTIONS="--json-location-accuracy 1 --write-json /run/readsb --write-json-every 1"
LAT="${LATITUDE}"
LON="${LONGITUDE}"
ALT="${ALTITUDE_M}m"
READSB

    systemctl enable readsb
    systemctl restart readsb
    sleep 3
    log "readsb: $(systemctl is-active readsb)"
}

# ═══════════════════════════════════════════════════════════════════
# dump978-fa (978 MHz UAT decoder — US only, optional)
# Built from source because the FlightAware apt repo is unreliable.
# Requires Boost and SoapySDR (installed in base deps).
# ═══════════════════════════════════════════════════════════════════
install_dump978() {
    is_yes "$ENABLE_UAT" || return 0
    banner "Installing dump978-fa (UAT decoder)"

    if dpkg -l dump978-fa 2>/dev/null | grep -q '^ii'; then
        log "dump978-fa already installed — skipping build"
    else
        cd /tmp
        rm -rf dump978-build
        git clone https://github.com/flightaware/dump978.git dump978-build
        cd dump978-build
        dpkg-buildpackage -b --no-sign || true
        cd /tmp
        dpkg -i dump978-fa_*.deb skyaware978_*.deb 2>/dev/null || \
            apt-get install -f -y -qq
    fi

    local uat_receiver_opts="--sdr driver=rtlsdr --format CS8"
    if [[ -n "$SDR_SERIAL_978" ]]; then
        uat_receiver_opts="--sdr driver=rtlsdr,serial=${SDR_SERIAL_978} --format CS8"
    fi

    mkdir -p /etc/default
    cat > /etc/default/dump978-fa <<DUMP978
RECEIVER_OPTIONS="${uat_receiver_opts}"
DECODER_OPTIONS="--json-stdout"
NET_OPTIONS="--raw-port 30978 --json-port 30979"
DUMP978

    systemctl enable dump978-fa 2>/dev/null || true
    systemctl restart dump978-fa 2>/dev/null || true
    log "dump978-fa: $(systemctl is-active dump978-fa 2>/dev/null || echo 'not running')"
}

# ═══════════════════════════════════════════════════════════════════
# tar1090 (local web map)
# ═══════════════════════════════════════════════════════════════════
install_tar1090() {
    banner "Installing tar1090"

    if [[ -d /usr/local/share/tar1090 ]] && ! is_yes "$FORCE_REINSTALL"; then
        log "tar1090 already installed — skipping"
    else
        curl -sL -o /tmp/tar1090-install.sh \
            https://github.com/wiedehopf/tar1090/raw/master/install.sh
        bash /tmp/tar1090-install.sh
    fi

    local ip
    ip="$(hostname -I | awk '{print $1}')"
    log "tar1090 — http://${ip}/tar1090"
}

# ═══════════════════════════════════════════════════════════════════
# readsb-based aggregator feeders (adsb.lol, adsb.fi, ADSBx,
# airplanes.live)
#
# All four share the ADS-B Exchange feedclient layout:
#   feed.sh  → clones repo to $IPATH/git, runs setup.sh
#   setup.sh → configure.sh (whiptail prompts → /etc/default/<feed>)
#              then update.sh
#   update.sh → clones/compiles their readsb fork + mlat-client venv,
#               installs <feed>-feed and <feed>-mlat services. If
#               /etc/default/<feed> already has every required key it
#               NEVER calls setup.sh, so there is nothing to prompt.
#
# So instead of driving whiptail, we write /etc/default/<feed> with
# exactly what configure.sh would have written, clone the repo, and run
# update.sh directly. Works identically attended and unattended.
#
# Per-feeder values below are copied verbatim from each project's
# configure.sh (2026-09).
# ═══════════════════════════════════════════════════════════════════
# write_feeder_config <cfg> <results2> <results3> <results4> <mlatserver> <target> <net_options>
write_feeder_config() {
    local cfg="$1" results2="$2" results3="$3" results4="$4" mlatserver="$5" target="$6" net_options="$7"
    cat > "$cfg" <<FEEDCFG
INPUT="127.0.0.1:${BEAST_BIND_PORT}"
REDUCE_INTERVAL="0.5"
USER="${MLAT_SITE_NAME_SAFE}"
LATITUDE="${LATITUDE}"
LONGITUDE="${LONGITUDE}"
ALTITUDE="${ALTITUDE_M}m"
UAT_INPUT="127.0.0.1:30978"
RESULTS="--results beast,connect,127.0.0.1:30104"
RESULTS2="${results2}"
RESULTS3="${results3}"
RESULTS4="${results4}"
PRIVACY=""
INPUT_TYPE="dump1090"
MLATSERVER="${mlatserver}"
TARGET="${target}"
NET_OPTIONS="${net_options}"
JSON_OPTIONS="--max-range 450 --json-location-accuracy 2 --range-outline-hours 24"
FEEDCFG
}

# install_readsb_feeder <label> <ipath> <repo> <branch> <service-prefix>
# Expects /etc/default/<cfg> to already be written by write_feeder_config.
install_readsb_feeder() {
    local label="$1" ipath="$2" repo="$3" branch="$4" svc="$5"

    if systemctl is-active --quiet "${svc}-feed" 2>/dev/null && ! is_yes "$FORCE_REINSTALL"; then
        log "$label feed already running — config refreshed, restarting"
        systemctl restart "${svc}-feed" 2>/dev/null || true
        systemctl restart "${svc}-mlat" 2>/dev/null || true
        return 0
    fi

    mkdir -p "$ipath"
    rm -rf "${ipath}/git"
    if ! git clone -q --depth 1 --single-branch --branch "$branch" "$repo" "${ipath}/git" 2>&1; then
        warn "Could not clone $label feed client ($repo) — skipping"
        return 0
    fi

    # update.sh emits whiptail-gauge progress numbers on stdout; harmless.
    if ! bash "${ipath}/git/update.sh" </dev/null 2>&1; then
        warn "$label update.sh returned non-zero — check ${ipath}/lastlog"
        return 0
    fi

    systemctl restart "${svc}-feed" 2>/dev/null || true
    systemctl restart "${svc}-mlat" 2>/dev/null || true
    log "$label: feed $(systemctl is-active "${svc}-feed" 2>/dev/null || echo 'not running'), mlat $(systemctl is-active "${svc}-mlat" 2>/dev/null || echo 'not running')"
}

install_feed_adsblol() {
    is_yes "$FEED_ADSBLOL" || return 0
    banner "Feed: adsb.lol"

    # Tracks wiedehopf/readsb@stale — already has the GCC 15 fix
    write_feeder_config /etc/default/adsblol \
        "--results basestation,listen,31420" \
        "--results beast,listen,31422" \
        "--results beast,connect,127.0.0.1:31421" \
        "feed.adsb.lol:31090" \
        "--net-connector feed.adsb.lol,30004,beast_reduce_plus_out,feed2.adsb.lol,1337" \
        "--net-heartbeat 60 --net-ro-size 1280 --net-ro-interval=0.05 --net-ro-interval-beast-reduce=0.12 --net-ro-port 0 --net-sbs-port 0 --net-bi-port 31421 --net-bo-port 0 --net-ri-port 0 --write-json-every 1"
    restore_feeder_uuid "adsb.lol" /usr/local/share/adsblol/adsblol-uuid "$ADSBLOL_UUID"
    install_readsb_feeder "adsb.lol" /usr/local/share/adsblol \
        https://github.com/adsblol/feed.git master adsblol
}

install_feed_adsbfi() {
    is_yes "$FEED_ADSBFI" || return 0
    banner "Feed: adsb.fi"

    # Compiles adsbfi/readsb@dev (frozen 2024-06) → needs -Werror wrapper
    write_feeder_config /etc/default/adsbfi \
        "--results basestation,listen,31009" \
        "--results beast,listen,30157" \
        "--results beast,connect,127.0.0.1:30169" \
        "feed.adsb.fi:31090" \
        "--net-connector feed.adsb.fi,30004,beast_reduce_plus_out,feed.adsb.fi,64004" \
        "--net-heartbeat 60 --net-ro-size 1280 --net-ro-interval 0.2 --net-ro-port 0 --net-sbs-port 0 --net-bi-port 30169 --net-bo-port 0 --net-ri-port 0 --write-json-every 1 --uuid-file /usr/local/share/adsbfi/adsbfi-uuid"
    restore_feeder_uuid "adsb.fi" /usr/local/share/adsbfi/adsbfi-uuid "$ADSBFI_UUID"
    install_readsb_feeder "adsb.fi" /usr/local/share/adsbfi \
        https://github.com/adsbfi/adsb-fi-scripts.git master adsbfi
}

install_feed_adsbx() {
    is_yes "$FEED_ADSBX" || return 0
    banner "Feed: ADS-B Exchange"

    # Compiles adsbexchange/readsb@master (frozen 2024-06) → needs -Werror wrapper
    write_feeder_config /etc/default/adsbexchange \
        "--results basestation,listen,31003" \
        "--results beast,listen,30157" \
        "--results beast,connect,127.0.0.1:30154" \
        "feed.adsbexchange.com:31090" \
        "--net-connector feed1.adsbexchange.com,30004,beast_reduce_out,feed2.adsbexchange.com,64004" \
        "--net-heartbeat 60 --net-ro-size 1280 --net-ro-interval 0.2 --net-ro-port 0 --net-sbs-port 0 --net-bi-port 30154 --net-bo-port 0 --net-ri-port 0 --write-json-every 1"
    restore_feeder_uuid "ADS-B Exchange" /usr/local/share/adsbexchange/adsbx-uuid "$ADSBX_UUID"
    install_readsb_feeder "ADS-B Exchange" /usr/local/share/adsbexchange \
        https://github.com/adsbexchange/feedclient.git master adsbexchange
}

install_feed_airplaneslive() {
    is_yes "$FEED_AIRPLANESLIVE" || return 0
    banner "Feed: airplanes.live"

    # Compiles airplanes-live/readsb@dev (synced 2026-05) — already fixed.
    # Note: service/config names are "airplanes", not "airplaneslive".
    write_feeder_config /etc/default/airplanes \
        "--results basestation,listen,31015" \
        "--results beast,listen,30157" \
        "--results beast,connect,127.0.0.1:30187" \
        "feed.airplanes.live:31090" \
        "--net-connector feed.airplanes.live,30004,beast_reduce_plus_out,feed.airplanes.live,64004" \
        "--net-heartbeat 60 --net-ro-size 1280 --net-ro-interval 0.2 --net-ro-port 0 --net-sbs-port 0 --net-bi-port 30187 --net-bo-port 0 --net-ri-port 0 --write-json-every 1 --uuid-file /usr/local/share/airplanes/airplanes-uuid"
    restore_feeder_uuid "airplanes.live" /usr/local/share/airplanes/airplanes-uuid "$AIRPLANES_UUID"
    install_readsb_feeder "airplanes.live" /usr/local/share/airplanes \
        https://github.com/airplanes-live/feed.git main airplanes
}

# ═══════════════════════════════════════════════════════════════════
# FlightAware / PiAware — pre-built .deb, configured via piaware-config
# ═══════════════════════════════════════════════════════════════════
install_feed_flightaware() {
    is_yes "$FEED_FLIGHTAWARE" || return 0
    banner "Feed: FlightAware / PiAware"

    if dpkg -l piaware 2>/dev/null | grep -q '^ii'; then
        log "PiAware already installed — skipping"
    else
        # Install via FA's apt repo .deb (more reliable than manual repo setup)
        if [[ ! -f /etc/apt/sources.list.d/flightaware.list ]]; then
            curl -fsSL -o /tmp/fa-repo.deb \
                "https://www.flightaware.com/adsb/piaware/files/packages/pool/piaware/f/flightaware-apt-repository/flightaware-apt-repository_1.2_all.deb" 2>/dev/null || true
            if [[ -f /tmp/fa-repo.deb ]]; then
                dpkg -i /tmp/fa-repo.deb 2>/dev/null || true
                apt-get update -qq 2>/dev/null || true
            fi
        fi
        apt-get install -y -qq piaware 2>/dev/null || {
            warn "PiAware apt install failed — may need manual install"
            return 0
        }
    fi

    if command -v piaware-config &>/dev/null; then
        piaware-config receiver-type other
        piaware-config receiver-host 127.0.0.1
        piaware-config receiver-port "$BEAST_BIND_PORT"
        piaware-config allow-auto-updates yes
        piaware-config allow-manual-updates yes
        piaware-config allow-mlat "$(is_yes "$ENABLE_MLAT" && echo yes || echo no)"
        if [[ -n "$FLIGHTAWARE_FEEDER_ID" ]]; then
            if [[ "$FLIGHTAWARE_FEEDER_ID" =~ $UUID_RE ]]; then
                piaware-config feeder-id "$FLIGHTAWARE_FEEDER_ID"
                log "FlightAware: restored feeder-id"
            else
                warn "FLIGHTAWARE_FEEDER_ID is not a valid UUID — ignoring"
            fi
        fi
        systemctl enable piaware 2>/dev/null || true
        systemctl restart piaware 2>/dev/null || true
        log "PiAware: $(systemctl is-active piaware 2>/dev/null || echo 'not running') — claim at https://flightaware.com/adsb/piaware/claim"
    fi
}

# ═══════════════════════════════════════════════════════════════════
# OpenSky Network — pre-built .deb, configured via debconf
#
# The package is "opensky-feeder" but its debconf templates are named
# "openskyd/*". Preseeding "opensky-feeder/latitude" (a natural guess)
# does nothing, and the package's Perl config script then loops forever
# re-asking for a valid latitude under a noninteractive frontend — the
# infamous "OpenSky dpkg infinite loop". The postinst writes
# /var/lib/openskyd/conf.d/10-debconf.conf from these answers.
# ═══════════════════════════════════════════════════════════════════
install_feed_opensky() {
    is_yes "$FEED_OPENSKY" || return 0
    banner "Feed: OpenSky Network"

    if systemctl is-active --quiet opensky-feeder 2>/dev/null && ! is_yes "$FORCE_REINSTALL"; then
        log "OpenSky feeder already running — skipping"
        return 0
    fi

    local deb_arch
    deb_arch="$(dpkg --print-architecture)"
    local opensky_deb=""

    for url in \
        "https://opensky-network.org/files/firmware/opensky-feeder_latest_${deb_arch}.deb" \
        "https://opensky-network.org/files/firmware/opensky-feeder_latest_armhf.deb"; do
        if curl -fsSL -o /tmp/opensky-feeder.deb "$url" 2>/dev/null && [[ -s /tmp/opensky-feeder.deb ]]; then
            opensky_deb="/tmp/opensky-feeder.deb"
            break
        fi
    done

    if [[ -z "$opensky_deb" ]]; then
        warn "Could not download OpenSky feeder package — skipping"
        return 0
    fi

    debconf-set-selections <<OSKSEED
opensky-feeder openskyd/latitude string ${LATITUDE}
opensky-feeder openskyd/longitude string ${LONGITUDE}
opensky-feeder openskyd/altitude string ${ALTITUDE_M}
opensky-feeder openskyd/dump1090branch select default
opensky-feeder openskyd/username string ${OPENSKY_USERNAME}
opensky-feeder openskyd/serial string ${OPENSKY_SERIAL}
opensky-feeder openskyd/host string localhost
opensky-feeder openskyd/port string ${BEAST_BIND_PORT}
OSKSEED

    dpkg -i "$opensky_deb" 2>&1 || apt-get install -f -y -qq 2>&1 || true

    systemctl enable opensky-feeder 2>/dev/null || true
    systemctl restart opensky-feeder 2>/dev/null || true
    log "OpenSky: $(systemctl is-active opensky-feeder 2>/dev/null || echo 'not running') — register at https://opensky-network.org/my-opensky"
}

# ═══════════════════════════════════════════════════════════════════
# FlightRadar24 — opt-in. Their installer needs an interactive signup
# (fr24feed --signup) and offers no pre-seed path, so it is skipped in
# non-interactive mode with a notice.
# ═══════════════════════════════════════════════════════════════════
install_feed_fr24() {
    is_yes "$FEED_FR24" || return 0
    banner "Feed: FlightRadar24"

    if command -v fr24feed &>/dev/null; then
        log "fr24feed already installed — skipping"
        return 0
    fi
    if [[ -n "$FR24_KEY" ]]; then
        # A saved sharing key means no signup is needed. Their installer may
        # still stop at its signup step when unattended (harmless); the ini
        # written below is what fr24feed actually reads.
        run_installer_script "https://repo-feed.flightradar24.com/install_fr24_rpi.sh" "fr24" || true
        cat > /etc/fr24feed.ini <<FR24INI
receiver="beast-tcp"
fr24key="${FR24_KEY}"
host="127.0.0.1:${BEAST_BIND_PORT}"
bs="no"
raw="no"
logmode="0"
mlat="yes"
mlat-without-gps="yes"
FR24INI
        systemctl restart fr24feed 2>/dev/null || true
        log "FR24: restored sharing key"
        return 0
    fi
    if $NON_INTERACTIVE; then
        warn "FR24 requires interactive signup — skipped. Run later: bash <(curl -fsSL https://repo-feed.flightradar24.com/install_fr24_rpi.sh)"
        return 0
    fi

    run_installer_script "https://repo-feed.flightradar24.com/install_fr24_rpi.sh" "fr24"
    log "FR24: if signup did not complete, run: sudo fr24feed --signup"
}

# ═══════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════
print_summary() {
    banner "Setup complete — adsb-node-bootstrap v${VERSION}"

    local ip
    ip="$(hostname -I | awk '{print $1}')"

    echo "  Location:  ${LATITUDE}, ${LONGITUDE} @ ${ALTITUDE_FT}ft / ${ALTITUDE_M}m"
    echo "  MLAT name: ${MLAT_SITE_NAME_SAFE}"
    echo "  tar1090:   http://${ip}/tar1090"
    echo "  Beast:     ${ip}:${BEAST_BIND_PORT}"
    echo ""
    echo "  Feeds:"
    for var_name in FEED_ADSBLOL FEED_FLIGHTAWARE FEED_ADSBFI FEED_ADSBX FEED_AIRPLANESLIVE FEED_OPENSKY FEED_FR24; do
        local pretty="${var_name#FEED_}"
        pretty="${pretty,,}"
        if is_yes "${!var_name}"; then
            echo -e "    ${GREEN}✓${NC} ${pretty}"
        else
            echo -e "    - ${pretty} (skipped)"
        fi
    done

    echo ""
    echo "  UAT:       $(is_yes "$ENABLE_UAT" && echo "enabled" || echo "disabled")"
    echo "  MLAT:      $(is_yes "$ENABLE_MLAT" && echo "enabled" || echo "disabled")"

    if [[ -n "$SDR_SERIAL_1090" ]]; then
        echo "  1090 SDR:  serial ${SDR_SERIAL_1090}"
    fi
    if is_yes "$ENABLE_UAT" && [[ -n "$SDR_SERIAL_978" ]]; then
        echo "  978 SDR:   serial ${SDR_SERIAL_978}"
    fi

    echo ""
    if is_yes "$FEED_FLIGHTAWARE"; then
        echo -e "  ${YELLOW}→ Claim FlightAware station:${NC} https://flightaware.com/adsb/piaware/claim"
    fi
    if is_yes "$FEED_OPENSKY"; then
        echo -e "  ${YELLOW}→ Register OpenSky account:${NC} https://opensky-network.org/my-opensky"
    fi

    echo ""
    echo "  Verify:"
    echo "    journalctl -u readsb --no-pager -n 20"
    echo "    systemctl status adsblol-feed adsbfi-feed adsbexchange-feed airplanes-feed piaware opensky-feeder"
    echo "    jq '.last1min.messages, .last1min.tracks.all' /run/readsb/stats.json"
    echo "  Log:       ${LOG_FILE}"
    echo "  Identity:  /etc/adsb-node-uuids.env  (back this up — restores the station on a reimage)"
    echo ""
    log "Done. Reboot recommended if this is a first install."
}

# ═══════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════
main() {
    echo ""
    echo "  adsb-node-bootstrap v${VERSION}"
    echo "  https://github.com/hank19CH/adsb-node-bootstrap"
    echo ""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)          CONFIG_FILE="$2"; shift 2 ;;
            --non-interactive) NON_INTERACTIVE=true; shift ;;
            --force)           FORCE_REINSTALL=yes; shift ;;
            --restore-uuids)   RESTORE_UUIDS="$2"; shift 2 ;;
            --help|-h)
                echo "Usage: sudo ./bootstrap.sh [--config config.env] [--non-interactive] [--force] [--restore-uuids uuids.env]"
                exit 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done

    if [[ -n "$CONFIG_FILE" ]]; then
        [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
        log "Loading config from $CONFIG_FILE"
        set -a; source "$CONFIG_FILE"; set +a
        NON_INTERACTIVE=true
    fi

    check_root

    # Everything after this point is also appended to the log file
    mkdir -p "$(dirname "$LOG_FILE")"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "=== adsb-node-bootstrap v${VERSION} started: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

    detect_arch
    detect_os
    detect_gcc_version

    load_restore_uuids
    prompt_config
    validate_config

    set_system_identity
    install_base_deps
    setup_rtlsdr_blacklist
    install_werror_fix      # Wrappers in PATH for all subsequent builds
    install_readsb
    install_tar1090
    install_dump978

    # Feeds — priority order
    install_feed_adsblol
    install_feed_flightaware
    install_feed_adsbfi
    install_feed_adsbx
    install_feed_airplaneslive
    install_feed_opensky
    install_feed_fr24

    remove_werror_fix
    capture_uuids

    print_summary
    echo "=== adsb-node-bootstrap finished: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
}

main "$@"
