#!/bin/bash
set -euo pipefail

# ============================================================
# R_SH Kubernetes Installer v2.0
# Health Check Functions
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "${SCRIPT_DIR}/common.sh" ]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/common.sh"
else
  echo "ERROR: common.sh not found"
  exit 1
fi

# ============================================================
# Helpers
# ============================================================

health_section() {
  echo
  line
  echo "$1"
  line
}

health_command_check() {
  local cmd="$1"

  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd installed"
    return 0
  else
    fail "$cmd not installed"
    return 1
  fi
}

health_service_check() {
  local service_name="$1"

  if systemctl list-unit-files | grep -q "^${service_name}.service"; then
    if systemctl is-active --quiet "$service_name"; then
      ok "$service_name service is running"
      return 0
    else
      fail "$service_name service is not running"
      return 1
    fi
  else
    fail "$service_name service not found"
    return 1
  fi
}

health_file_check() {
  local file_path="$1"
  local title="$2"

  if [ -f "$file_path" ]; then
    ok "$title exists: $file_path"
    return 0
  else
    fail "$title not found: $file_path"
    return 1
  fi
}

health_dir_check() {
  local dir_path="$1"
  local title="$2"

  if [ -d "$dir_path" ]; then
    ok "$title exists: $dir_path"
    return 0
  else
    fail "$title not found: $dir_path"
    return 1
  fi
}

# ============================================================
# OS Health
# ============================================================

health_os_info() {
  health_section "System Information"

  echo "Hostname : $(hostname)"
  echo "OS       : $(. /etc/os-release && echo "$PRETTY_NAME")"
  echo "Kernel   : $(uname -r)"
  echo "IP       : $(hostname -I | awk '{print $1}')"
  echo "CPU      : $(nproc) Core"
  echo "Memory   : $(free -h | awk '/Mem:/ {print $2}')"
  echo
}

health_swap_check() {
  health_section "Swap Check"

  if swapon --summary | grep -q .; then
    fail "Swap is enabled"
    swapon --summary || true
    return 1
  else
    ok "Swap is disabled"
    return 0
  fi
}

health_kernel_modules_check() {
  health_section "Kernel Modules Check"

  local failed=0

  if lsmod | grep -q "^overlay"; then
    ok "overlay module loaded"
  else
    fail "overlay module not loaded"
    failed=1
  fi

  if lsmod | grep -q "^br_netfilter"; then
    ok "br_netfilter module loaded"
  else
    fail "br_netfilter module not loaded"
    failed=1
  fi

  return "$failed"
}

health_sysctl_check() {
  health_section "Sysctl Check"

  local failed=0

  local bridge_iptables
  local bridge_ip6tables
  local ip_forward

  bridge_iptables="$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null || echo "missing")"
  bridge_ip6tables="$(sysctl -n net.bridge.bridge-nf-call-ip6tables 2>/dev/null || echo "missing")"
  ip_forward="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "missing")"

  if [ "$bridge_iptables" = "1" ]; then
    ok "net.bridge.bridge-nf-call-iptables = 1"
  else
    fail "net.bridge.bridge-nf-call-iptables = ${bridge_iptables}"
    failed=1
  fi

  if [ "$bridge_ip6tables" = "1" ]; then
    ok "net.bridge.bridge-nf-call-ip6tables = 1"
  else
    fail "net.bridge.bridge-nf-call-ip6tables = ${bridge_ip6tables}"
    failed=1
  fi

  if [ "$ip_forward" = "1" ]; then
    ok "net.ipv4.ip_forward = 1"
  else
    fail "net.ipv4.ip_forward = ${ip_forward}"
    failed=1
  fi

  return "$failed"
}

# ============================================================
# Runtime Health
# ============================================================

health_runtime_commands_check() {
  health_section "Runtime Commands Check"

  local failed=0

  health_command_check runc || failed=1
  health_command_check containerd || failed=1
  health_command_check ctr || failed=1

  return "$failed"
}

health_containerd_check() {
  health_section "Containerd Check"

  local failed=0

  health_service_check containerd || failed=1

  if [ -f /etc/containerd/config.toml ]; then
    ok "containerd config exists"
  else
    fail "containerd config not found"
    failed=1
  fi

  if grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
    ok "containerd SystemdCgroup = true"
  else
    fail "containerd SystemdCgroup is not true"
    failed=1
  fi

  if command -v ctr >/dev/null 2>&1; then
    if ctr version >/dev/null 2>&1; then
      ok "ctr can communicate with containerd"
    else
      fail "ctr cannot communicate with containerd"
      failed=1
    fi
  else
    fail "ctr command not found"
    failed=1
  fi

  return "$failed"
}

health_cni_check() {
  health_section "CNI Check"

  local failed=0

  health_dir_check /opt/cni/bin "CNI bin directory" || failed=1

  if [ -d /opt/cni/bin ]; then
    local cni_count
    cni_count="$(find /opt/cni/bin -maxdepth 1 -type f | wc -l)"

    if [ "$cni_count" -gt 0 ]; then
      ok "CNI plugins found: ${cni_count}"
    else
      fail "No CNI plugin files found in /opt/cni/bin"
      failed=1
    fi
  fi

  return "$failed"
}

# ============================================================
# Kubernetes Local Health
# ============================================================

health_kubernetes_commands_check() {
  health_section "Kubernetes Commands Check"

  local failed=0

  health_command_check kubeadm || failed=1
  health_command_check kubelet || failed=1
  health_command_check kubectl || failed=1

  return "$failed"
}

health_kubelet_check() {
  health_section "Kubelet Check"

  local failed=0

  health_service_check kubelet || failed=1

  if [ -f /etc/default/kubelet ]; then
    ok "/etc/default/kubelet exists"
  else
    warn "/etc/default/kubelet not found"
  fi

  return "$failed"
}

health_kubernetes_files_check() {
  health_section "Kubernetes Files Check"

  local failed=0

  if [ -d /etc/kubernetes ]; then
    ok "/etc/kubernetes directory exists"
  else
    warn "/etc/kubernetes directory not found"
  fi

  if [ -f /etc/kubernetes/admin.conf ]; then
    ok "admin.conf exists. This node looks like a control-plane node."
  else
    warn "admin.conf not found. This is normal on worker nodes."
  fi

  if [ -f "$HOME/.kube/config" ]; then
    ok "kubectl config exists: $HOME/.kube/config"
  else
    warn "kubectl config not found in $HOME/.kube/config"
  fi

  return "$failed"
}

# ============================================================
# Kubernetes Cluster Health
# ============================================================

detect_kubectl_config() {
  if [ -f "$HOME/.kube/config" ]; then
    export KUBECONFIG="$HOME/.kube/config"
    return 0
  fi

  if [ -f /etc/kubernetes/admin.conf ]; then
    export KUBECONFIG="/etc/kubernetes/admin.conf"
    return 0
  fi

  return 1
}

health_cluster_check() {
  health_section "Kubernetes Cluster Check"

  if ! command -v kubectl >/dev/null 2>&1; then
    warn "kubectl not found. Skipping cluster check."
    return 0
  fi

  if ! detect_kubectl_config; then
    warn "kubectl config not found. Skipping cluster check."
    warn "This is normal on worker nodes."
    return 0
  fi

  if ! kubectl cluster-info >/dev/null 2>&1; then
    fail "kubectl cannot connect to Kubernetes API"
    return 1
  fi

  ok "kubectl can connect to Kubernetes API"

  echo
  info "Nodes:"
  kubectl get nodes -o wide || true

  echo
  info "Pods:"
  kubectl get pods -A || true

  echo
  info "Component pods in kube-system:"
  kubectl get pods -n kube-system || true

  return 0
}

health_container_images_check() {
  health_section "Container Images Check"

  if ! command -v ctr >/dev/null 2>&1; then
    warn "ctr not found. Skipping image check."
    return 0
  fi

  if ! systemctl is-active --quiet containerd; then
    warn "containerd is not running. Skipping image check."
    return 0
  fi

  local image_count
  image_count="$(ctr -n k8s.io images list 2>/dev/null | tail -n +2 | wc -l || echo 0)"

  if [ "$image_count" -gt 0 ]; then
    ok "Images found in containerd k8s.io namespace: ${image_count}"
    ctr -n k8s.io images list 2>/dev/null | head -30 || true
  else
    warn "No images found in containerd k8s.io namespace"
  fi

  return 0
}

# ============================================================
# Offline Package Health
# ============================================================

health_offline_packages_check() {
  health_section "Offline Packages Check"

  echo "Do you want to verify offline packages?"
  echo
  echo "1) Yes"
  echo "2) No"
  echo

  read -rp "Select [1-2]: " verify_choice

  case "$verify_choice" in
    1)
      select_k8s_version
      verify_offline_packages || true
      ;;
    2)
      info "Skipping offline package verification."
      ;;
    *)
      warn "Invalid option. Skipping offline package verification."
      ;;
  esac
}

# ============================================================
# Main Health Check
# ============================================================

run_health_check() {
  setup_logging
  show_banner

  local failed=0

  health_os_info

  health_swap_check || failed=1
  health_kernel_modules_check || failed=1
  health_sysctl_check || failed=1

  health_runtime_commands_check || failed=1
  health_containerd_check || failed=1
  health_cni_check || failed=1

  health_kubernetes_commands_check || failed=1
  health_kubelet_check || failed=1
  health_kubernetes_files_check || failed=1

  health_container_images_check || true
  health_cluster_check || failed=1

  echo
  line
  echo "Health Check Summary"
  line

  if [ "$failed" -eq 0 ]; then
    ok "Overall status: HEALTHY"
  else
    fail "Overall status: NEEDS ATTENTION"
  fi

  echo
  echo "Log file:"
  echo "$LOG_FILE"

  pause
}