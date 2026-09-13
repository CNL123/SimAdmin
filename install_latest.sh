#!/bin/sh
set -eu

# SimAdmin Optimized Installer
# Source: https://github.com/3899/SimAdmin
# Optimized: fix asset filename version suffix bug, add --skip-verify, OpenWrt procd support

# -------------------------- Config & Default --------------------------
GH_PROXY="${GH_PROXY:-}"
REPO="3899/SimAdmin"
VERSION="latest"
VARIANT=""
ASSET_NAME=""
INSTALL_DIR="/opt/simadmin"
SERVICE_NAME="simadmin"
DEPS_MODE="auto"
MODEM_PROTOCOL="auto"
REFRESH_MODEM=1
INSTALL_LPAC=1
SKIP_VERIFY=0

# -------------------------- Help Text --------------------------
usage() {
cat <<EOF
SimAdmin optimized install script
Usage: $0 [OPTIONS]
Options:
  -v, --version VERSION    Target version, default latest
  --full                   Install full variant
  --volte                  Install volte variant
  --vowifi,--wfc           Install vowifi/wfc variant
  -a,--asset NAME          Force asset filename (highest priority)
  --install-dir PATH       Install directory, default /opt/simadmin
  --service-name NAME      Service name
  --deps-mode MODE         auto/minimal/full/skip
  --modem-protocol MODE    auto/qmi/mbim/at/all
  --refresh-modem          Force modem refresh (default on)
  --no-refresh-modem       Disable modem refresh
  --no-lpac                Skip lpac install
  --skip-verify            Skip SHA256 digest verification (use carefully!)
  -h,--help                Show this help
EOF
exit 0
}

# -------------------------- Parse Args --------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--version) VERSION="$2"; shift 2 ;;
        --full) VARIANT="full"; shift ;;
        --volte) VARIANT="volte"; shift ;;
        --vowifi|--wfc) VARIANT="vowifi"; shift ;;
        -a|--asset) ASSET_NAME="$2"; shift 2 ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --service-name) SERVICE_NAME="$2"; shift 2 ;;
        --deps-mode) DEPS_MODE="$2"; shift 2 ;;
        --modem-protocol) MODEM_PROTOCOL="$2"; shift 2 ;;
        --refresh-modem) REFRESH_MODEM=1; shift ;;
        --no-refresh-modem) REFRESH_MODEM=0; shift ;;
        --no-lpac) INSTALL_LPAC=0; shift ;;
        --skip-verify) SKIP_VERIFY=1; shift ;;
        -h|--help) usage ;;
        *) echo "error: unknown option: $1"; usage ;;
    esac
done

# Env override
VERSION="${VERSION:-${SIMADMIN_VERSION:-$VERSION}}"
VARIANT="${VARIANT:-${SIMADMIN_VARIANT:-$VARIANT}}"
ASSET_NAME="${ASSET_NAME:-${SIMADMIN_ASSET_NAME:-$ASSET_NAME}}"

# -------------------------- URL Helper --------------------------
gh_url() {
    local raw="$1"
    if [ -n "$GH_PROXY" ]; then
        echo "${GH_PROXY%/}/$raw"
    else
        echo "$raw"
    fi
}

# -------------------------- Arch detect --------------------------
detect_arch() {
    case $(uname -m) in
        aarch64|arm64) echo "aarch64" ;;
        armv7*) echo "armv7" ;;
        x86_64) echo "x86_64" ;;
        *) echo "unknown" ;;
    esac
}
ARCH=$(detect_arch)
echo "==> Detected arch: $ARCH"

# -------------------------- Fetch release API --------------------------
fetch_release() {
    local ver="$1"
    local api_url
    if [ "$ver" = "latest" ]; then
        api_url="https://api.github.com/repos/${REPO}/releases/latest"
    else
        api_url="https://api.github.com/repos/${REPO}/releases/tags/${ver}"
    fi
    curl -fsSLk "$(gh_url "$api_url")"
}

# -------------------------- Find asset (FIX: tolerate version suffix in filename) --------------------------
find_asset() {
    local api_json="$1"
    local want_variant="$2"
    local arch="$3"
    local asset_name_force="$4"

    if [ -n "$asset_name_force" ]; then
        echo "$asset_name_force"
        return 0
    fi

    # jq filter: find asset contains variant + arch, ends with .tar.gz
    echo "$api_json" | jq -r --arg v "$want_variant" --arg a "$arch" '
        .assets[] | select(.name | contains($v) and contains($a) and endswith(".tar.gz")) | .name
    ' | head -n1
}

# -------------------------- Get SHA256 from release assets --------------------------
get_asset_sha256() {
    local api_json="$1"
    local asset_name="$2"
    echo "$api_json" | jq -r --arg n "$asset_name" '
        .assets[] | select(.name == $n) | .digest_sha256
    '
}

# -------------------------- Main install --------------------------
main() {
    echo "==> installing SimAdmin"
    echo "    version: ${VERSION}"
    echo "    variant: ${VARIANT}"
    echo "    install dir: ${INSTALL_DIR}"
    echo "    service name: ${SERVICE_NAME}"
    echo "    skip verify: ${SKIP_VERIFY}"

    # Deps check
    echo "==> checking dependencies"
    if ! command -v curl >/dev/null; then echo "curl required"; exit 1; fi
    if ! command -v jq >/dev/null; then echo "jq required"; exit 1; fi
    if ! command -v tar >/dev/null; then echo "tar required"; exit 1; fi

    echo "==> fetch release metadata from GitHub API"
    RELEASE_JSON=$(fetch_release "$VERSION")
    FOUND_ASSET=$(find_asset "$RELEASE_JSON" "$VARIANT" "$ARCH" "$ASSET_NAME")
    if [ -z "$FOUND_ASSET" ]; then
        echo "error: cannot find matching asset for variant=${VARIANT} arch=${ARCH}"
        exit 1
    fi
    echo "==> matched release asset: ${FOUND_ASSET}"

    EXPECT_SHA=$(get_asset_sha256 "$RELEASE_JSON" "$FOUND_ASSET")

    # Build download URL
    TAG_NAME=$(echo "$RELEASE_JSON" | jq -r '.tag_name')
    DL_RAW="https://github.com/${REPO}/releases/download/${TAG_NAME}/${FOUND_ASSET}"
    DL_URL=$(gh_url "$DL_RAW")
    echo "==> downloading: ${DL_URL}"

    TMP_TGZ=$(mktemp /tmp/simadmin.XXXXXX.tar.gz)
    curl -fsSLk "$DL_URL" -o "$TMP_TGZ"

    # SHA256 verify logic
    if [ "$SKIP_VERIFY" -eq 1 ]; then
        echo "⚠️  --skip-verify enabled, skip SHA256 check"
    elif [ -z "$EXPECT_SHA" ] || [ "$EXPECT_SHA" = "null" ]; then
        echo "⚠️  No trusted SHA-256 digest found for ${FOUND_ASSET}"
        echo "    Use --skip-verify to continue without hash check"
        rm -f "$TMP_TGZ"
        exit 1
    else
        echo "==> verifying SHA256"
        LOCAL_SHA=$(sha256sum "$TMP_TGZ" | awk '{print $1}')
        if [ "$LOCAL_SHA" != "$EXPECT_SHA" ]; then
            echo "error: SHA256 mismatch! expected:${EXPECT_SHA}, got:${LOCAL_SHA}"
            rm -f "$TMP_TGZ"
            exit 1
        fi
    fi

    # Extract
    echo "==> extract to ${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}"
    tar -zxf "$TMP_TGZ" -C "${INSTALL_DIR}"
    chmod +x "${INSTALL_DIR}/bin/"*
    rm -f "$TMP_TGZ"

    # Create service: detect OpenWrt (procd) vs systemd
    if [ -f /etc/openwrt_release ]; then
        echo "==> OpenWrt detected, generate procd init service /etc/init.d/${SERVICE_NAME}"
        cat > "/etc/init.d/${SERVICE_NAME}" <<EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command ${INSTALL_DIR}/bin/simadmin
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
        chmod +x "/etc/init.d/${SERVICE_NAME}"
        "/etc/init.d/${SERVICE_NAME}" enable
        echo "==> procd service created, start with: /etc/init.d/${SERVICE_NAME} start"
    else
        echo "==> systemd system detected, write /etc/systemd/system/${SERVICE_NAME}.service"
        cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=SimAdmin
After=network.target

[Service]
ExecStart=${INSTALL_DIR}/bin/simadmin
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "${SERVICE_NAME}"
        echo "==> systemd service created, start with: systemctl start ${SERVICE_NAME}"
    fi

    echo "✅ SimAdmin install complete, web: http://<router-ip>:8080"
}

main
