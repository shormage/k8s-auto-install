#!/bin/bash
set -euo pipefail

# ============================================================
# R_SH Kubernetes Installer v2.0
# Reset Functions
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
# Reset Kubernetes Cluster
# ============================================================

reset_kubernetes_cluster() {
  setup_logging
  show_banner
  check_root

  warn "This action will reset Kubernetes on this node."
  warn "It will remove kubeadm configuration, etcd data on master, and kubeconfig."
  echo
  echo "This does NOT remove:"
  echo "- containerd"
  echo "- runc"
  echo "- CNI binaries"
  echo "- kubeadm / kubelet / kubectl packages"
  echo "- files inside packages/"
  echo
  read -rp "To continue, type YES: " confirm

  if [ "$confirm" != "YES" ]; then
    warn "Reset cancelled."
    pause
    return 0
  fi

  echo
  info "Running kubeadm reset..."

  if command -v kubeadm >/dev/null 2>&1; then
    kubeadm reset -f || true
    ok "kubeadm reset completed"
  else
    warn "kubeadm command not found. Skipping kubeadm reset."
  fi

  echo
  info "Removing Kubernetes configuration files..."

  rm -rf /etc/kubernetes/*
  rm -rf /var/lib/etcd
  rm -rf "$HOME/.kube"

  ok "Kubernetes config and etcd data removed"

  echo
  info "Cleaning CNI runtime state..."

  rm -rf /etc/cni/net.d/*
  rm -rf /var/lib/cni/*
  rm -rf /var/lib/kubelet/pod-resources
  rm -rf /var/lib/kubelet/plugins
  rm -rf /var/lib/kubelet/plugins_registry

  ok "CNI and kubelet runtime state cleaned"

  echo
  info "Restarting services..."

  systemctl restart containerd || true
  systemctl restart kubelet || true

  ok "Services restarted"

  echo
  line
  ok "Kubernetes reset completed successfully."
  line

  pause
}

# ============================================================
# Full Kubernetes Uninstall
# Optional, more destructive than reset
# ============================================================

uninstall_kubernetes_components() {
  setup_logging
  show_banner
  check_root

  warn "This action will uninstall Kubernetes packages and remove runtime files."
  warn "Use this only if you want to clean the node completely."
  echo
  echo "This WILL remove:"
  echo "- kubeadm"
  echo "- kubelet"
  echo "- kubectl"
  echo "- /etc/kubernetes"
  echo "- /var/lib/etcd"
  echo "- /var/lib/kubelet"
  echo "- /etc/cni/net.d"
  echo
  echo "This will NOT remove:"
  echo "- packages/"
  echo "- logs/"
  echo
  read -rp "To continue, type UNINSTALL: " confirm

  if [ "$confirm" != "UNINSTALL" ]; then
    warn "Uninstall cancelled."
    pause
    return 0
  fi

  echo
  info "Resetting kubeadm first..."

  if command -v kubeadm >/dev/null 2>&1; then
    kubeadm reset -f || true
  fi

  echo
  info "Stopping services..."

  systemctl stop kubelet || true
  systemctl stop containerd || true

  echo
  info "Removing Kubernetes packages..."

  apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
  apt-get remove -y kubelet kubeadm kubectl || true
  apt-get purge -y kubelet kubeadm kubectl || true
  apt-get autoremove -y || true

  echo
  info "Removing Kubernetes directories..."

  rm -rf /etc/kubernetes
  rm -rf /var/lib/etcd
  rm -rf /var/lib/kubelet
  rm -rf /etc/cni/net.d
  rm -rf /var/lib/cni
  rm -rf "$HOME/.kube"

  echo
  info "Removing Kubernetes apt repository..."

  rm -f /etc/apt/sources.list.d/kubernetes.list
  rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  systemctl daemon-reload || true

  echo
  line
  ok "Kubernetes components uninstalled successfully."
  line

  pause
}

# ============================================================
# Reset Menu
# ============================================================

reset_menu() {
  while true; do
    show_banner

    echo "Reset / Cleanup Menu"
    echo
    echo "1) Reset Kubernetes Cluster"
    echo "2) Full Uninstall Kubernetes Components"
    echo "3) Back"
    echo

    read -rp "Select [1-3]: " reset_choice

    case "$reset_choice" in
      1)
        reset_kubernetes_cluster
        ;;
      2)
        uninstall_kubernetes_components
        ;;
      3)
        return 0
        ;;
      *)
        warn "Invalid option."
        sleep 1
        ;;
    esac
  done
}