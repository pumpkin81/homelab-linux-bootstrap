#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="2.0.0"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info(){ echo -e "${BLUE}[INFO]${NC} $*"; }
ok(){ echo -e "${GREEN}[ OK ]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
fail(){ echo -e "${RED}[FAIL]${NC} $*" >&2; }

[[ $EUID -eq 0 ]] || { fail "Run this script with sudo or as root."; exit 1; }
[[ -r /etc/os-release ]] || { fail "/etc/os-release is unavailable."; exit 1; }
# shellcheck disable=SC1091
source /etc/os-release
DISTRO="${ID,,}"; DISTRO_NAME="${PRETTY_NAME:-$ID}"; DISTRO_LIKE="${ID_LIKE:-}"; DISTRO_VERSION="${VERSION_ID:-unknown}"

case "$DISTRO" in
  ubuntu|debian|linuxmint|pop) FAMILY="debian" ;;
  fedora|rocky|almalinux|rhel|centos) FAMILY="rhel" ;;
  *)
    [[ "$DISTRO_LIKE" == *debian* ]] && FAMILY="debian" || FAMILY="unknown"
    [[ "$DISTRO_LIKE" == *rhel* || "$DISTRO_LIKE" == *fedora* ]] && FAMILY="rhel"
    ;;
esac
[[ "$FAMILY" != unknown ]] || { fail "Unsupported distro: $DISTRO_NAME"; exit 1; }

VIRT_TYPE="none"
command -v systemd-detect-virt >/dev/null 2>&1 && VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || true)"
[[ -n "$VIRT_TYPE" ]] || VIRT_TYPE="none"
case "$VIRT_TYPE" in
  lxc) PLATFORM="LXC container" ;;
  kvm|qemu) PLATFORM="KVM/QEMU virtual machine" ;;
  none) PLATFORM="Physical machine or undetected" ;;
  *) PLATFORM="$VIRT_TYPE virtualized system" ;;
esac

# When run with sudo, customize the invoking user. When run directly as root, customize root.
TARGET_USER="${SUDO_USER:-root}"
[[ "$TARGET_USER" != "root" ]] && ! id "$TARGET_USER" >/dev/null 2>&1 && TARGET_USER="root"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" ]] || TARGET_HOME="/root"

CORE_DEBIAN=(curl wget git vim nano htop tree unzip zip rsync jq tmux screen less lsof bash-completion ca-certificates gnupg kitty)
CORE_RHEL=(curl wget git vim nano htop tree unzip zip rsync jq tmux screen less lsof bash-completion ca-certificates gnupg2 kitty)
NETWORK_DEBIAN=(dnsutils net-tools iproute2 iputils-ping traceroute tcpdump nmap netcat-openbsd ethtool openssh-client openssh-server mtr-tiny)
NETWORK_RHEL=(bind-utils net-tools iproute iputils traceroute tcpdump nmap nmap-ncat ethtool openssh-clients openssh-server mtr)
STORAGE_DEBIAN=(smartmontools hdparm parted ncdu iotop fio lsscsi gdisk)
STORAGE_RHEL=(smartmontools hdparm parted ncdu iotop fio lsscsi gdisk)
SMB_DEBIAN=(cifs-utils smbclient nfs-common)
SMB_RHEL=(cifs-utils samba-client nfs-utils)
MONITORING_DEBIAN=(sysstat lm-sensors iotop procps)
MONITORING_RHEL=(sysstat lm_sensors iotop procps-ng)
SHELL_DEBIAN=(zsh fzf lsd)
SHELL_RHEL=(zsh fzf lsd)

CORE=false; NETWORK=false; STORAGE=false; SMB=false; DOCKER=false; MONITORING=false; SHELL=false
ASSUME_YES=false; VALIDATION_FAILURES=0; INSTALLED_PROFILES=()

header(){
  echo -e "${CYAN}${BOLD}\nHomelab Linux Bootstrap v$VERSION${NC}"
  printf '%s\n' "OS: $DISTRO_NAME" "Family: $FAMILY" "Platform: $PLATFORM" "Target user: $TARGET_USER"
}
usage(){
  cat <<EOF
Usage: sudo $0 [options]
  --core --network --storage --smb --docker --monitoring --shell
  --recommended   core + network + monitoring + shell
  --all           every profile
  --yes           non-interactive confirmations
  --list          list profiles
  --help
EOF
}
list_profiles(){
  cat <<'EOF'
core          Base CLI tools plus Kitty terminal
network       Network diagnostics and OpenSSH
storage       Disk and filesystem utilities
smb           SMB/CIFS, Samba client, and NFS client
shell         Zsh, Oh My Zsh, fzf, lsd, aliases, and default shell
monitoring    sysstat, sensors, iotop, and process tools
docker        Docker Engine and Compose plugin
recommended   core + network + shell + monitoring
all           Every profile
EOF
}
select_recommended(){ CORE=true; NETWORK=true; SHELL=true; MONITORING=true; }
select_all(){ select_recommended; STORAGE=true; SMB=true; DOCKER=true; }

interactive_menu(){
  header
  cat <<'EOF'
Select profiles using space-separated numbers:
  1) Core
  2) Network
  3) Storage
  4) SMB / NFS
  5) Docker
  6) Monitoring
  7) Shell customization
  8) Recommended (Core + Network + Monitoring + Shell)
  9) Everything
  0) Exit
EOF
  read -r -p "Selection: " choices
  for choice in $choices; do
    case "$choice" in
      1) CORE=true;; 2) NETWORK=true;; 3) STORAGE=true;; 4) SMB=true;;
      5) DOCKER=true;; 6) MONITORING=true;; 7) SHELL=true;;
      8) select_recommended;; 9) select_all;; 0) exit 0;; *) warn "Ignoring unknown choice: $choice";;
    esac
  done
}
parse_args(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --core) CORE=true;; --network) NETWORK=true;; --storage) STORAGE=true;;
      --smb) SMB=true;; --docker) DOCKER=true;; --monitoring) MONITORING=true;;
      --shell) SHELL=true;; --recommended) select_recommended;; --all) select_all;;
      --yes|-y) ASSUME_YES=true;; --list) list_profiles; exit 0;; --help|-h) usage; exit 0;;
      *) fail "Unknown option: $1"; usage; exit 1;;
    esac
    shift
  done
}
selected_any(){ $CORE || $NETWORK || $STORAGE || $SMB || $DOCKER || $MONITORING || $SHELL; }

update_metadata(){
  if [[ "$FAMILY" == debian ]]; then
    export DEBIAN_FRONTEND=noninteractive; apt-get update
  else
    dnf makecache -y
  fi
}
package_available(){
  if [[ "$FAMILY" == debian ]]; then apt-cache show "$1" >/dev/null 2>&1; else dnf -q list --available "$1" >/dev/null 2>&1 || rpm -q "$1" >/dev/null 2>&1; fi
}
install_packages(){
  local required=() optional=() pkg
  while [[ $# -gt 0 && "$1" != "--optional" ]]; do required+=("$1"); shift; done
  [[ $# -gt 0 ]] && shift
  optional=("$@")
  if [[ "$FAMILY" == debian ]]; then
    ((${#required[@]})) && apt-get install -y "${required[@]}"
  else
    ((${#required[@]})) && dnf install -y "${required[@]}"
  fi
  for pkg in "${optional[@]}"; do
    if package_available "$pkg"; then
      [[ "$FAMILY" == debian ]] && apt-get install -y "$pkg" || dnf install -y "$pkg"
    else
      warn "Optional package '$pkg' is unavailable in enabled repositories; skipped."
    fi
  done
}
family_packages(){
  local deb_name="$1" rhel_name="$2"; shift 2
  local -n arr="$deb_name"; [[ "$FAMILY" == rhel ]] && local -n arr="$rhel_name"
  install_packages "${arr[@]}" "$@"
}

install_core(){
  info "Installing core profile..."
  # Kitty is optional because headless/minimal repositories may not carry it.
  if [[ "$FAMILY" == debian ]]; then
    local pkgs=("${CORE_DEBIAN[@]}"); unset 'pkgs[${#pkgs[@]}-1]'; install_packages "${pkgs[@]}" --optional kitty
  else
    local pkgs=("${CORE_RHEL[@]}"); unset 'pkgs[${#pkgs[@]}-1]'; install_packages "${pkgs[@]}" --optional kitty
  fi
  INSTALLED_PROFILES+=(core); ok "Core installed."
}
install_network(){
  info "Installing network profile..."; family_packages NETWORK_DEBIAN NETWORK_RHEL
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || warn "SSH service could not be enabled automatically."
  fi
  INSTALLED_PROFILES+=(network); ok "Network installed."
}
install_storage(){
  [[ "$VIRT_TYPE" == lxc ]] && warn "Low-level storage tools have limited visibility inside LXC."
  family_packages STORAGE_DEBIAN STORAGE_RHEL; INSTALLED_PROFILES+=(storage); ok "Storage installed."
}
install_smb(){ family_packages SMB_DEBIAN SMB_RHEL; INSTALLED_PROFILES+=(smb); ok "SMB/NFS installed."; }
install_monitoring(){ family_packages MONITORING_DEBIAN MONITORING_RHEL; INSTALLED_PROFILES+=(monitoring); ok "Monitoring installed."; }

append_once(){ local line="$1" file="$2"; touch "$file"; grep -Fqx "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"; }
install_shell(){
  info "Installing shell customization for $TARGET_USER..."
  family_packages SHELL_DEBIAN SHELL_RHEL
  local zsh_path; zsh_path="$(command -v zsh)"
  if [[ ! -d "$TARGET_HOME/.oh-my-zsh" ]]; then
    info "Installing Oh My Zsh unattended..."
    if [[ "$TARGET_USER" == root ]]; then
      HOME="$TARGET_HOME" RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" -- --unattended
    else
      sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" -- --unattended
    fi
  else
    info "Oh My Zsh already exists; leaving it in place."
  fi
  local zrc="$TARGET_HOME/.zshrc"
  [[ -f "$zrc" ]] || printf '%s\n' 'export ZSH="$HOME/.oh-my-zsh"' 'ZSH_THEME="robbyrussell"' 'plugins=(git)' 'source $ZSH/oh-my-zsh.sh' > "$zrc"
  append_once '# Homelab bootstrap shell customizations' "$zrc"
  append_once 'alias ls="lsd"' "$zrc"
  append_once 'alias ll="lsd -la"' "$zrc"
  append_once 'alias la="lsd -A"' "$zrc"
  append_once '[[ -f ~/.fzf.zsh ]] && source ~/.fzf.zsh' "$zrc"
  # Most distro fzf packages expose completion/key bindings here.
  append_once '[[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]] && source /usr/share/doc/fzf/examples/key-bindings.zsh' "$zrc"
  append_once '[[ -f /usr/share/doc/fzf/examples/completion.zsh ]] && source /usr/share/doc/fzf/examples/completion.zsh' "$zrc"
  chown -R "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$TARGET_HOME/.zshrc" "$TARGET_HOME/.oh-my-zsh" 2>/dev/null || true
  usermod -s "$zsh_path" "$TARGET_USER"
  INSTALLED_PROFILES+=(shell); ok "Zsh configured. It becomes active at the next login."
}

install_docker(){
  if [[ "$VIRT_TYPE" == lxc && "$ASSUME_YES" != true ]]; then
    warn "Docker in Proxmox LXC commonly needs nesting enabled on the Proxmox host."
    read -r -p "Continue? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || { warn "Docker skipped."; return; }
  fi
  info "Installing Docker Engine..."
  if [[ "$FAMILY" == debian ]]; then
    install_packages ca-certificates curl gnupg
    apt-get remove -y docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc >/dev/null 2>&1 || true
    install -m 0755 -d /etc/apt/keyrings
    local repo_os="$DISTRO"
    [[ "$repo_os" != ubuntu && "$repo_os" != debian ]] && repo_os="${DISTRO_LIKE%% *}"
    [[ "$repo_os" == ubuntu || "$repo_os" == debian ]] || { fail "Cannot safely map $DISTRO to a Docker APT repository."; return 1; }
    curl -fsSL "https://download.docker.com/linux/$repo_os/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    local codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    [[ -n "$codename" ]] || { fail "Distribution codename not found."; return 1; }
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$repo_os $codename stable" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    dnf install -y dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  systemctl enable --now docker >/dev/null 2>&1 || warn "Docker service could not be started."
  INSTALLED_PROFILES+=(docker); ok "Docker installed."
}
configure_virtualization(){
  if [[ "$VIRT_TYPE" == kvm || "$VIRT_TYPE" == qemu ]]; then
    info "Installing QEMU guest agent for the detected VM."
    install_packages qemu-guest-agent
    systemctl enable --now qemu-guest-agent >/dev/null 2>&1 || warn "Enable the QEMU Guest Agent option in Proxmox, then restart the guest agent."
  elif [[ "$VIRT_TYPE" == lxc ]]; then
    info "LXC detected; QEMU guest agent skipped."
  fi
}

check(){ local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else fail "$label"; ((VALIDATION_FAILURES+=1)); fi; }
validate(){
  echo -e "\n${BOLD}Final validation${NC}"
  check "Package manager available" bash -c 'command -v apt-get >/dev/null || command -v dnf >/dev/null'
  check "Default route present" ip route get 1.1.1.1
  check "DNS resolution works" getent hosts github.com
  check "HTTPS connectivity works" curl -fsSIL --max-time 10 https://github.com
  $CORE && check "Core command: jq" command -v jq
  $CORE && { command -v kitty >/dev/null 2>&1 && ok "Kitty installed" || warn "Kitty unavailable/skipped (normal on some headless or minimal repos)."; }
  $NETWORK && check "SSH server executable available" bash -c 'command -v sshd >/dev/null'
  $STORAGE && check "Storage command: ncdu" command -v ncdu
  $SMB && check "SMB command: smbclient" command -v smbclient
  $MONITORING && check "Monitoring command: sar" command -v sar
  if $SHELL; then
    check "Zsh available" command -v zsh
    check "fzf available" command -v fzf
    check "lsd available" command -v lsd
    check "Oh My Zsh installed" test -d "$TARGET_HOME/.oh-my-zsh"
    check "Default shell is zsh for $TARGET_USER" bash -c "getent passwd '$TARGET_USER' | grep -q '$(command -v zsh)$'"
    check "ls alias present" grep -Fqx 'alias ls="lsd"' "$TARGET_HOME/.zshrc"
  fi
  $DOCKER && check "Docker service active" systemctl is-active --quiet docker
  $DOCKER && check "Docker Compose plugin available" docker compose version
  if [[ "$VIRT_TYPE" == kvm || "$VIRT_TYPE" == qemu ]]; then
    check "QEMU guest agent installed" command -v qemu-ga
  fi
  echo
  if ((VALIDATION_FAILURES == 0)); then ok "All required validation checks passed."; else warn "$VALIDATION_FAILURES validation check(s) failed. Review the messages above."; fi
}
cleanup(){
  if [[ "$FAMILY" == debian ]]; then apt-get autoremove -y; apt-get clean; else dnf clean all; fi
}
main(){
  if (($# == 0)); then interactive_menu; else header; parse_args "$@"; fi
  selected_any || { fail "No profile selected."; exit 1; }
  update_metadata
  $CORE && install_core
  $NETWORK && install_network
  $STORAGE && install_storage
  $SMB && install_smb
  $DOCKER && install_docker
  $MONITORING && install_monitoring
  $SHELL && install_shell
  configure_virtualization
  cleanup
  validate
  echo -e "\n${BOLD}Installed profiles:${NC} ${INSTALLED_PROFILES[*]:-none}"
  echo "OS: $DISTRO_NAME | Platform: $PLATFORM | User: $TARGET_USER"
  $SHELL && echo "Log out and back in to begin using Zsh."
  ((VALIDATION_FAILURES == 0))
}
main "$@"
