#!/bin/bash
set -euo pipefail

# ============================================================
# R_SH Kubernetes Installer v2.0
# Install Functions
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
# Selection Guard
# ============================================================

ensure_install_selection() {
  if [ -z "${K8S_VERSION:-}" ]; then
    select_k8s_version
  fi

  if [ -z "${INSTALL_MODE:-}" ]; then
    select_install_mode
  fi

  prepare_package_paths
  show_runtime_summary

  if is_offline_mode; then
    require_offline_packages
  fi
}

# ============================================================
# DPKG Repair For Install
# ============================================================

repair_dpkg_for_install() {
  wait_for_apt_locks

  if is_offline_mode; then
    info "Offline mode: running dpkg configure only."
    dpkg --configure -a || true
  else
    fix_dpkg
  fi
}

# ============================================================
# OS Base Packages
# ============================================================

install_os_base_packages() {
  if is_offline_mode; then
    info "Offline mode: skipping OS package installation from internet."
    ok "OS base package step skipped in offline mode"
    return 0
  fi

  safe_apt_update
  safe_apt_install curl wget gpg ca-certificates apt-transport-https tar
}

# ============================================================
# Install runc
# ============================================================

install_runc_runtime() {
  info "Installing runc..."

  if [ -f "$RUNC_FILE" ]; then
    info "Using local runc file: $RUNC_FILE"
  else
    if is_offline_mode; then
      fail "Offline mode: runc file not found: $RUNC_FILE"
      return 1
    fi

    info "Downloading runc..."
    mkdir -p "$PACKAGE_DIR"
    wget -O "$RUNC_FILE" \
      "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64"
  fi

  install -m 755 "$RUNC_FILE" /usr/local/sbin/runc
  ok "runc installed"
}

# ============================================================
# Install CNI Plugins
# ============================================================

install_cni_plugins_runtime() {
  info "Installing CNI plugins..."

  if [ -f "$CNI_FILE" ]; then
    info "Using local CNI package: $CNI_FILE"
  else
    if is_offline_mode; then
      fail "Offline mode: CNI package not found: $CNI_FILE"
      return 1
    fi

    info "Downloading CNI plugins..."
    mkdir -p "$PACKAGE_DIR"
    wget -O "$CNI_FILE" \
      "https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/cni-plugins-linux-amd64-v${CNI_VERSION}.tgz"
  fi

  mkdir -p /opt/cni/bin
  tar Cxzvf /opt/cni/bin "$CNI_FILE"

  ok "CNI plugins installed"
}

# ============================================================
# Install containerd
# ============================================================

write_containerd_service() {
  mkdir -p /usr/local/lib/systemd/system

  cat >/usr/local/lib/systemd/system/containerd.service <<EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target dbus.service

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd

Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5

LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF
}

configure_containerd() {
  mkdir -p /etc/containerd

  containerd config default > /etc/containerd/config.toml

  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
  sed -i -E "s#sandbox = 'registry\.k8s\.io/pause:[^']+'#sandbox = '${PAUSE_IMAGE}'#g" /etc/containerd/config.toml
  sed -i -E "s#sandbox_image = \"registry\.k8s\.io/pause:[^\"]+\"#sandbox_image = \"${PAUSE_IMAGE}\"#g" /etc/containerd/config.toml

  systemctl daemon-reload
  systemctl enable --now containerd
  systemctl restart containerd
  systemctl restart kubelet || true

  ok "containerd configured with SystemdCgroup=true and pause image ${PAUSE_IMAGE}"
}

install_containerd_runtime() {
  info "Installing containerd..."

  if [ -f "$CONTAINERD_FILE" ]; then
    info "Using local containerd package: $CONTAINERD_FILE"
  else
    if is_offline_mode; then
      fail "Offline mode: containerd package not found: $CONTAINERD_FILE"
      return 1
    fi

    info "Downloading containerd..."
    mkdir -p "$PACKAGE_DIR"
    wget -O "$CONTAINERD_FILE" \
      "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
  fi

  tar Cxzvf /usr/local "$CONTAINERD_FILE"

  write_containerd_service
  configure_containerd

  ok "containerd installed"
}

# ============================================================
# Install Kubernetes Tools
# kubeadm / kubelet / kubectl
# ============================================================

install_kubernetes_tools_offline() {
  info "Installing Kubernetes tools from local deb archive..."

  if [ ! -f "$K8S_DEBS_FILE" ]; then
    fail "Offline mode: Kubernetes deb archive not found: $K8S_DEBS_FILE"
    return 1
  fi

  local tmp_dir="/tmp/r_sh-k8s-debs"

  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"

  tar -xzvf "$K8S_DEBS_FILE" -C "$tmp_dir"

  if ! ls "$tmp_dir"/*.deb >/dev/null 2>&1; then
    fail "No .deb files found inside $K8S_DEBS_FILE"
    return 1
  fi

  dpkg -i "$tmp_dir"/*.deb

  apt-mark hold kubelet kubeadm kubectl || true
  systemctl enable --now kubelet

  ok "Kubernetes tools installed from offline package"
}

install_kubernetes_tools_online() {
  info "Installing Kubernetes tools from official repository..."

  mkdir -p /etc/apt/keyrings

  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

  apt-get update
  apt-get install -y kubelet kubeadm kubectl

  apt-mark hold kubelet kubeadm kubectl
  systemctl enable --now kubelet

  ok "Kubernetes tools installed online"
}

install_kubernetes_tools() {
  if is_offline_mode; then
    install_kubernetes_tools_offline
  else
    install_kubernetes_tools_online
  fi
}

# ============================================================
# Import Kubernetes Images
# ============================================================

import_kubernetes_images() {
  if is_offline_mode; then
    info "Importing Kubernetes images from local archive..."

    if [ -f "$IMAGES_FILE" ]; then
      info "Importing single image archive: $IMAGES_FILE"
      ctr -n k8s.io images import "$IMAGES_FILE"
      ok "Images imported from $IMAGES_FILE"
      print_available_pause_images
      return 0
    fi

    local image_bundle_file=""

    case "$K8S_VERSION" in
      v1.34)
        if [ -f "$IMAGES_BUNDLE_FILE" ]; then
          image_bundle_file="$IMAGES_BUNDLE_FILE"
        fi
        ;;
      v1.35)
        if [ -f "$K8S_IMAGES_BUNDLE_FILE" ]; then
          image_bundle_file="$K8S_IMAGES_BUNDLE_FILE"
        elif [ -f "$IMAGES_BUNDLE_FILE" ]; then
          image_bundle_file="$IMAGES_BUNDLE_FILE"
        fi
        ;;
      *)
        fail "Unsupported Kubernetes version for image import: $K8S_VERSION"
        return 1
        ;;
    esac

    if [ -n "$image_bundle_file" ]; then
      info "Importing image bundle archive: $image_bundle_file"

      local tmp_images_dir="/tmp/r_sh-images-${K8S_VERSION}"

      rm -rf "$tmp_images_dir"
      mkdir -p "$tmp_images_dir"

      tar -xzf "$image_bundle_file" -C "$tmp_images_dir"

      if ! ls "$tmp_images_dir"/*.tar >/dev/null 2>&1; then
        fail "No .tar image files found inside $image_bundle_file"
        return 1
      fi

      for image_tar in "$tmp_images_dir"/*.tar; do
        info "Importing $image_tar"
        ctr -n k8s.io images import "$image_tar"
      done

      ok "All images imported from $image_bundle_file"
      print_available_pause_images
      return 0
    fi

    fail "Offline mode: no image archive found."
    echo "Expected one of:"
    echo "$IMAGES_FILE"
    if [ "$K8S_VERSION" = "v1.35" ]; then
      echo "$K8S_IMAGES_BUNDLE_FILE"
      echo "$IMAGES_BUNDLE_FILE"
    else
      echo "$IMAGES_BUNDLE_FILE"
    fi
    return 1

  else
    info "Online mode: skipping local image import."
  fi
}

image_exists_in_containerd() {
  local image="$1"

  ctr -n k8s.io images ls -q 2>/dev/null | awk -v img="$image" '$0 == img { found=1 } END { exit !found }'
}

print_available_pause_images() {
  ctr -n k8s.io images ls -q 2>/dev/null | grep 'registry.k8s.io/pause:' || true
}

verify_pause_image() {
  if ! is_offline_mode; then
    return 0
  fi

  info "Checking pause image in containerd: ${PAUSE_IMAGE}"

  if image_exists_in_containerd "$PAUSE_IMAGE"; then
    ok "Pause image found: ${PAUSE_IMAGE}"
    return 0
  fi

  warn "Pause image was not found with exact match."
  warn "Expected: ${PAUSE_IMAGE}"
  warn "Available pause images:"
  print_available_pause_images

  fail "Pause image not found in containerd namespace k8s.io."
  return 1
}

# ============================================================
# Install Calico
# ============================================================

install_calico_network() {
  info "Installing Calico..."

  if [ -f "$CALICO_FILE" ]; then
    info "Using local Calico file: $CALICO_FILE"
    kubectl apply -f "$CALICO_FILE"
  else
    if is_offline_mode; then
      fail "Offline mode: Calico file not found: $CALICO_FILE"
      return 1
    fi

    info "Downloading Calico manifest..."
    mkdir -p "$PACKAGE_DIR"
    wget -O "$CALICO_FILE" \
      "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

    kubectl apply -f "$CALICO_FILE"
  fi

  ok "Calico installed"
}

# ============================================================
# Node Common Preparation
# ============================================================

prepare_node_common() {
  check_root
  setup_logging

  run_step "Repair dpkg status" repair_dpkg_for_install
  run_step "Install OS base packages" install_os_base_packages
  run_step "Disable swap" disable_swap
  run_step "Enable kernel modules" enable_kernel_modules
  run_step "Configure sysctl" configure_sysctl
  run_step "Install runc" install_runc_runtime
  run_step "Install CNI plugins" install_cni_plugins_runtime
  run_step "Install containerd" install_containerd_runtime
  run_step "Install Kubernetes tools" install_kubernetes_tools
  run_step "Import Kubernetes images" import_kubernetes_images
  run_step "Verify pause image" verify_pause_image
}

# ============================================================
# Master Installation
# ============================================================

configure_kubectl_for_root() {
  mkdir -p "$HOME/.kube"
  cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
  chown "$(id -u):$(id -g)" "$HOME/.kube/config"

  ok "kubectl configured for current user"
}

generate_join_command() {
  kubeadm token create --print-join-command > "${SCRIPT_DIR}/join-command.sh"
  chmod +x "${SCRIPT_DIR}/join-command.sh"

  ok "Join command generated: ${SCRIPT_DIR}/join-command.sh"
}

install_master_node() {
  show_banner
  ensure_install_selection

  echo
  warn "Master installation will start now."
  read -rp "Continue? type YES: " confirm

  if [ "$confirm" != "YES" ]; then
    warn "Master installation cancelled."
    return 0
  fi

  prepare_node_common

  echo
  info "Initializing Kubernetes Control Plane..."

  kubeadm init --pod-network-cidr="$POD_CIDR"

  run_step "Configure kubectl" configure_kubectl_for_root
  run_step "Install Calico" install_calico_network
  run_step "Generate join command" generate_join_command

  echo
  ok "Master node installed successfully."

  echo
  kubectl get nodes || true
  echo
  kubectl get pods -A || true

  pause
}

# ============================================================
# Worker Installation
# ============================================================

join_worker_node() {
  echo
  echo "Worker Join Method:"
  echo
  echo "1) Use local join-command.sh"
  echo "2) Paste join command manually"
  echo

  read -rp "Select [1-2]: " join_choice

  case "$join_choice" in
    1)
      if [ ! -f "${SCRIPT_DIR}/join-command.sh" ]; then
        fail "join-command.sh not found in ${SCRIPT_DIR}"
        return 1
      fi

      bash "${SCRIPT_DIR}/join-command.sh"
      ;;
    2)
      read -rp "Paste kubeadm join command: " join_command

      if [ -z "$join_command" ]; then
        fail "Join command is empty"
        return 1
      fi

      eval "$join_command"
      ;;
    *)
      fail "Invalid join method selected."
      return 1
      ;;
  esac

  ok "Worker joined to cluster"
}

install_worker_node() {
  show_banner
  ensure_install_selection

  echo
  warn "Worker installation will start now."
  read -rp "Continue? type YES: " confirm

  if [ "$confirm" != "YES" ]; then
    warn "Worker installation cancelled."
    return 0
  fi

  prepare_node_common

  run_step "Join worker node" join_worker_node

  echo
  ok "Worker node installed successfully."

  pause
}
