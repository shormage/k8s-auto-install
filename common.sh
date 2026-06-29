#!/bin/bash
set -euo pipefail

# ============================================================
# R_SH Kubernetes Installer v2.0
# Common Functions
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: config.env not found in ${SCRIPT_DIR}"
  exit 1
fi

source "$CONFIG_FILE"

# ============================================================
# Global Variables
# ============================================================

K8S_VERSION=""
INSTALL_MODE=""

PACKAGE_DIR=""
CONTAINERD_FILE=""
RUNC_FILE=""
CNI_FILE=""
K8S_DEBS_FILE=""
CALICO_FILE=""
IMAGES_FILE=""
IMAGES_BUNDLE_FILE=""
K8S_IMAGES_BUNDLE_FILE=""

LOG_DIR="${SCRIPT_DIR}/${LOGS_DIR}"
mkdir -p "$LOG_DIR"

LOG_FILE="${LOG_DIR}/r_sh-install-$(date +%F).log"

# ============================================================
# Colors
# ============================================================

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
NC="\033[0m"

ok() {
  echo -e "${GREEN}[ OK ]${NC} $1"
}

fail() {
  echo -e "${RED}[FAIL]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

info() {
  echo -e "${CYAN}[INFO]${NC} $1"
}

line() {
  echo "============================================================"
}

pause() {
  echo
  read -rp "Press Enter to continue..."
}

clear_screen() {
  clear || true
}

# ============================================================
# Logging
# ============================================================

setup_logging() {
  mkdir -p "$LOG_DIR"

  if [ -z "${R_SH_LOGGING_ENABLED:-}" ]; then
    export R_SH_LOGGING_ENABLED="1"
    exec > >(tee -a "$LOG_FILE") 2>&1
  fi
}

# ============================================================
# Banner
# ============================================================

show_banner() {
  clear_screen
  line
  echo "          ${APP_NAME}"
  echo "                 Version ${APP_VERSION}"
  line
  echo
  echo "Hostname : $(hostname)"
  echo "OS       : $(. /etc/os-release && echo "$PRETTY_NAME")"
  echo "IP       : $(hostname -I | awk '{print $1}')"
  echo "CPU      : $(nproc) Core"
  echo "Memory   : $(free -h | awk '/Mem:/ {print $2}')"
  echo
}

# ============================================================
# Root Check
# ============================================================

check_root() {
  if [ "$EUID" -ne 0 ]; then
    fail "Please run this installer as root."
    echo
    echo "Example:"
    echo "sudo ./R_SH"
    exit 1
  fi
}

# ============================================================
# Version Selection
# ============================================================

select_k8s_version() {
  echo
  echo "Select Kubernetes Version:"
  echo
  echo "1) ${K8S_VERSION_1}"
  echo "2) ${K8S_VERSION_2}"
  echo

  read -rp "Select [1-2]: " version_choice

  case "$version_choice" in
    1)
      K8S_VERSION="$K8S_VERSION_1"
      ;;
    2)
      K8S_VERSION="$K8S_VERSION_2"
      ;;
    *)
      fail "Invalid Kubernetes version selected."
      exit 1
      ;;
  esac

  prepare_package_paths

  ok "Selected Kubernetes version: ${K8S_VERSION}"
}

# ============================================================
# Installation Mode Selection
# ============================================================

select_install_mode() {
  echo
  echo "Select Installation Mode:"
  echo
  echo "1) Offline"
  echo "2) Online"
  echo

  read -rp "Select [1-2]: " mode_choice

  case "$mode_choice" in
    1)
      INSTALL_MODE="offline"
      ;;
    2)
      INSTALL_MODE="online"
      ;;
    *)
      fail "Invalid installation mode selected."
      exit 1
      ;;
  esac

  ok "Selected installation mode: ${INSTALL_MODE}"
}

is_offline_mode() {
  [ "${INSTALL_MODE}" = "offline" ]
}

is_online_mode() {
  [ "${INSTALL_MODE}" = "online" ]
}

# ============================================================
# Package Paths
# ============================================================

prepare_package_paths() {
  if [ -z "${K8S_VERSION}" ]; then
    fail "Kubernetes version is not selected."
    exit 1
  fi

  PACKAGE_DIR="${SCRIPT_DIR}/${PACKAGES_DIR}/${K8S_VERSION}"

  CONTAINERD_FILE="${PACKAGE_DIR}/${CONTAINERD_PACKAGE}"
  RUNC_FILE="${PACKAGE_DIR}/${RUNC_PACKAGE}"
  CNI_FILE="${PACKAGE_DIR}/${CNI_PACKAGE}"
  K8S_DEBS_FILE="${PACKAGE_DIR}/kubernetes-${K8S_VERSION}-debs.tar.gz"
  CALICO_FILE="${PACKAGE_DIR}/${CALICO_PACKAGE}"
  IMAGES_FILE="${PACKAGE_DIR}/images-${K8S_VERSION}.tar"
  IMAGES_BUNDLE_FILE="${PACKAGE_DIR}/k8s-${K8S_VERSION}-offline.tar.gz"
  K8S_IMAGES_BUNDLE_FILE=""

  if [ "$K8S_VERSION" = "v1.35" ]; then
    K8S_IMAGES_BUNDLE_FILE="${PACKAGE_DIR}/k8s-images-v1.35.2.tar.gz"
  fi

  mkdir -p "$PACKAGE_DIR"

  export K8S_VERSION INSTALL_MODE PACKAGE_DIR
  export CONTAINERD_FILE RUNC_FILE CNI_FILE K8S_DEBS_FILE CALICO_FILE
  export IMAGES_FILE IMAGES_BUNDLE_FILE K8S_IMAGES_BUNDLE_FILE
}

show_selected_paths() {
  echo
  info "Package directory: ${PACKAGE_DIR}"
  echo "Containerd : ${CONTAINERD_FILE}"
  echo "runc       : ${RUNC_FILE}"
  echo "CNI        : ${CNI_FILE}"
  echo "K8S Debs   : ${K8S_DEBS_FILE}"
  echo "Calico     : ${CALICO_FILE}"
  echo "Images     : ${IMAGES_FILE}"
  echo "Bundle     : ${IMAGES_BUNDLE_FILE}"

  if [ -n "${K8S_IMAGES_BUNDLE_FILE:-}" ]; then
    echo "K8S Bundle : ${K8S_IMAGES_BUNDLE_FILE}"
  fi

  echo
}

# ============================================================
# Offline Package Verification
# ============================================================

verify_file_exists() {
  local file_path="$1"
  local file_name="$2"

  if [ -f "$file_path" ]; then
    ok "$file_name"
    return 0
  else
    fail "$file_name not found"
    return 1
  fi
}

verify_image_archive_exists() {
  if [ -f "$IMAGES_FILE" ]; then
    ok "images-${K8S_VERSION}.tar"
    return 0
  fi

  if [ "$K8S_VERSION" = "v1.35" ] && [ -f "$K8S_IMAGES_BUNDLE_FILE" ]; then
    ok "k8s-images-v1.35.2.tar.gz"
    return 0
  fi

  if [ -f "$IMAGES_BUNDLE_FILE" ]; then
    ok "k8s-${K8S_VERSION}-offline.tar.gz"
    return 0
  fi

  if [ "$K8S_VERSION" = "v1.35" ]; then
    fail "Image archive not found: images-v1.35.tar, k8s-images-v1.35.2.tar.gz, or k8s-v1.35-offline.tar.gz"
  else
    fail "Image archive not found: images-v1.34.tar or k8s-v1.34-offline.tar.gz"
  fi

  return 1
}

verify_offline_packages() {
  if [ -z "${K8S_VERSION}" ]; then
    select_k8s_version
  fi

  prepare_package_paths

  echo
  line
  echo "Checking offline packages for ${K8S_VERSION}"
  line
  echo
  echo "Directory:"
  echo "$PACKAGE_DIR"
  echo

  local missing=0

  verify_file_exists "$CONTAINERD_FILE" "$CONTAINERD_PACKAGE" || missing=1
  verify_file_exists "$RUNC_FILE" "$RUNC_PACKAGE" || missing=1
  verify_file_exists "$CNI_FILE" "$CNI_PACKAGE" || missing=1
  verify_file_exists "$K8S_DEBS_FILE" "kubernetes-${K8S_VERSION}-debs.tar.gz" || missing=1
  verify_file_exists "$CALICO_FILE" "$CALICO_PACKAGE" || missing=1
  verify_image_archive_exists || missing=1

  echo

  if [ "$missing" -eq 0 ]; then
    ok "Offline package status: READY"
    return 0
  else
    fail "Offline package status: NOT READY"
    echo
    echo "Please put all required files inside:"
    echo "$PACKAGE_DIR"
    return 1
  fi
}

require_offline_packages() {
  if is_offline_mode; then
    info "Offline mode selected. Verifying local packages..."
    verify_offline_packages
  fi
}

# ============================================================
# APT / DPKG Helpers
# ============================================================

wait_for_apt_locks() {
  info "Checking apt/dpkg locks..."

  while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        fuser /var/lib/apt/lists/lock >/dev/null 2>&1
  do
    warn "Waiting for apt/dpkg lock to be released..."
    sleep 3
  done
}

fix_dpkg() {
  info "Checking dpkg health..."

  mkdir -p /root/dpkg-backup

  if ls /var/lib/dpkg/updates/[0-9]* >/dev/null 2>&1; then
    warn "Found stale dpkg update files. Creating backup..."
    cp -a /var/lib/dpkg/updates "/root/dpkg-backup/updates-$(date +%F-%H%M%S)" || true
    rm -f /var/lib/dpkg/updates/*
  fi

  dpkg --configure -a || true
  apt-get install -f -y || true
}

safe_apt_update() {
  if is_offline_mode; then
    info "Offline mode: skipping apt-get update."
    return 0
  fi

  wait_for_apt_locks
  apt-get update
}

safe_apt_install() {
  if is_offline_mode; then
    fail "apt install is not allowed in Offline mode."
    return 1
  fi

  wait_for_apt_locks
  apt-get install -y "$@"
}

# ============================================================
# System Checks
# ============================================================

check_command_exists() {
  local cmd="$1"

  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd found"
    return 0
  else
    fail "$cmd not found"
    return 1
  fi
}

check_service_status() {
  local service_name="$1"

  if systemctl is-active --quiet "$service_name"; then
    ok "$service_name is running"
    return 0
  else
    fail "$service_name is not running"
    return 1
  fi
}

check_swap_disabled() {
  if swapon --summary | grep -q .; then
    fail "Swap is enabled"
    return 1
  else
    ok "Swap is disabled"
    return 0
  fi
}

check_kernel_module() {
  local module_name="$1"

  if lsmod | grep -q "^${module_name}"; then
    ok "Kernel module loaded: ${module_name}"
    return 0
  else
    fail "Kernel module not loaded: ${module_name}"
    return 1
  fi
}

check_sysctl_value() {
  local key="$1"
  local expected="$2"
  local current

  current="$(sysctl -n "$key" 2>/dev/null || echo "")"

  if [ "$current" = "$expected" ]; then
    ok "$key = $expected"
    return 0
  else
    fail "$key expected $expected but got ${current:-empty}"
    return 1
  fi
}

# ============================================================
# Basic Kubernetes Prerequisites
# ============================================================

disable_swap() {
  info "Disabling swap..."

  swapoff -a || true

  if [ -f /etc/fstab ]; then
    sed -i.bak '/ swap / s/^/#/' /etc/fstab || true
    sed -i.bak '/\/swap.img/ s/^/#/' /etc/fstab || true
  fi

  ok "Swap disabled"
}

enable_kernel_modules() {
  info "Enabling Kubernetes kernel modules..."

  cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

  modprobe overlay
  modprobe br_netfilter

  ok "Kernel modules enabled"
}

configure_sysctl() {
  info "Configuring sysctl for Kubernetes..."

  cat >/etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

  sysctl --system

  ok "sysctl configured"
}

# ============================================================
# Step Wrapper
# ============================================================

run_step() {
  local step_name="$1"
  shift

  echo
  info "START: ${step_name}"

  if "$@"; then
    ok "DONE: ${step_name}"
  else
    fail "FAILED: ${step_name}"
    exit 1
  fi
}

# ============================================================
# Summary
# ============================================================

show_runtime_summary() {
  echo
  line
  echo "Runtime Summary"
  line
  echo "Kubernetes Version : ${K8S_VERSION:-not selected}"
  echo "Install Mode       : ${INSTALL_MODE:-not selected}"
  echo "Package Directory  : ${PACKAGE_DIR:-not selected}"
  echo "Pause Image        : ${PAUSE_IMAGE:-not configured}"
  echo "Log File           : ${LOG_FILE}"
  line
  echo
}
