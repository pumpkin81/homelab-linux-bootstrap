#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="3.0.0"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; REV='\033[7m'; NC='\033[0m'
info(){ printf '%b\n' "${BLUE}[INFO]${NC} $*"; }
ok(){ printf '%b\n' "${GREEN}[ OK ]${NC} $*"; }
warn(){ printf '%b\n' "${YELLOW}[WARN]${NC} $*"; }
fail(){ printf '%b\n' "${RED}[FAIL]${NC} $*" >&2; }

[[ $EUID -eq 0 ]] || { fail "Run with sudo or as root."; exit 1; }
[[ -r /etc/os-release ]] || { fail "/etc/os-release is unavailable."; exit 1; }
# shellcheck disable=SC1091
source /etc/os-release
DISTRO="${ID,,}"; DISTRO_NAME="${PRETTY_NAME:-$ID}"; DISTRO_LIKE="${ID_LIKE:-}"
case "$DISTRO" in
  ubuntu|debian|linuxmint|pop) FAMILY=debian ;;
  fedora|rocky|almalinux|rhel|centos) FAMILY=rhel ;;
  *)
    FAMILY=unknown
    [[ "$DISTRO_LIKE" == *debian* ]] && FAMILY=debian
    [[ "$DISTRO_LIKE" == *rhel* || "$DISTRO_LIKE" == *fedora* ]] && FAMILY=rhel
    ;;
esac
[[ "$FAMILY" != unknown ]] || { fail "Unsupported distribution: $DISTRO_NAME"; exit 1; }

VIRT_TYPE=none
if command -v systemd-detect-virt >/dev/null 2>&1; then
  VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || true)"; [[ -n "$VIRT_TYPE" ]] || VIRT_TYPE=none
fi
case "$VIRT_TYPE" in
  lxc) PLATFORM="LXC container";;
  kvm|qemu) PLATFORM="KVM/QEMU virtual machine";;
  none) PLATFORM="Physical machine or undetected";;
  *) PLATFORM="$VIRT_TYPE virtualized system";;
esac

TARGET_USER="${SUDO_USER:-root}"
id "$TARGET_USER" >/dev/null 2>&1 || TARGET_USER=root
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"; [[ -n "$TARGET_HOME" ]] || TARGET_HOME=/root

# Canonical application IDs. Distro-specific names are resolved by package_name().
PROFILE_ORDER=(core network storage smb docker monitoring shell)
declare -A PROFILE_LABEL=(
  [core]="Core utilities" [network]="Network tools" [storage]="Storage tools"
  [smb]="SMB / NFS clients" [docker]="Docker Engine" [monitoring]="Monitoring tools"
  [shell]="Shell customization"
)
declare -A PROFILE_APPS=(
  [core]="curl wget git vim nano tree unzip zip rsync jq tmux screen less lsof bash_completion ca_certificates gnupg"
  [network]="dns_tools net_tools iproute ping traceroute tcpdump nmap netcat ethtool openssh_client openssh_server mtr"
  [storage]="smartmontools hdparm parted ncdu iotop fio lsscsi gdisk"
  [smb]="cifs_utils smbclient nfs_client"
  [docker]="docker_engine"
  [monitoring]="htop sysstat sensors iotop procps"
  [shell]="zsh fzf lsd ohmyzsh zsh_default lsd_aliases"
)
declare -A APP_LABEL=(
  [curl]="curl" [wget]="wget" [git]="Git" [vim]="Vim" [nano]="Nano" [tree]="tree"
  [unzip]="unzip" [zip]="zip" [rsync]="rsync" [jq]="jq" [tmux]="tmux" [screen]="GNU screen"
  [less]="less" [lsof]="lsof" [bash_completion]="Bash completion" [ca_certificates]="CA certificates" [gnupg]="GnuPG"
  [dns_tools]="DNS tools (dig/nslookup)" [net_tools]="net-tools" [iproute]="iproute" [ping]="ping"
  [traceroute]="traceroute" [tcpdump]="tcpdump" [nmap]="nmap" [netcat]="netcat" [ethtool]="ethtool"
  [openssh_client]="OpenSSH client" [openssh_server]="OpenSSH server" [mtr]="mtr"
  [smartmontools]="smartmontools" [hdparm]="hdparm" [parted]="parted" [ncdu]="ncdu"
  [iotop]="iotop" [fio]="fio" [lsscsi]="lsscsi" [gdisk]="gdisk"
  [cifs_utils]="CIFS utilities" [smbclient]="SMB client" [nfs_client]="NFS client"
  [docker_engine]="Docker Engine + Compose plugin"
  [htop]="htop" [sysstat]="sysstat" [sensors]="lm-sensors" [procps]="process utilities"
  [zsh]="Zsh" [fzf]="fzf" [lsd]="lsd" [ohmyzsh]="Oh My Zsh"
  [zsh_default]="Set Zsh as default shell" [lsd_aliases]="Aliases: ls/ll/la use lsd"
)

declare -A PROFILE_SELECTED APP_SELECTED APP_OVERRIDE
for p in "${PROFILE_ORDER[@]}"; do PROFILE_SELECTED[$p]=false; done

set_profile(){
  local p="$1" value="$2" app
  PROFILE_SELECTED[$p]="$value"
  for app in ${PROFILE_APPS[$p]}; do
    [[ -n "${APP_OVERRIDE[$app]:-}" ]] || APP_SELECTED[$app]="$value"
  done
}
select_recommended(){
  local p
  for p in "${PROFILE_ORDER[@]}"; do set_profile "$p" false; done
  set_profile core true; set_profile network true; set_profile monitoring true; set_profile shell true
}
select_all(){ local p; for p in "${PROFILE_ORDER[@]}"; do set_profile "$p" true; done; }
clear_all(){ local p app; for p in "${PROFILE_ORDER[@]}"; do PROFILE_SELECTED[$p]=false; done; for app in "${!APP_SELECTED[@]}"; do APP_SELECTED[$app]=false; done; APP_OVERRIDE=(); }
select_recommended  # Recommended is preselected when the menu first opens.

package_name(){
  local app="$1"
  case "$app:$FAMILY" in
    bash_completion:*) echo bash-completion;; ca_certificates:*) echo ca-certificates;;
    gnupg:debian) echo gnupg;; gnupg:rhel) echo gnupg2;;
    dns_tools:debian) echo dnsutils;; dns_tools:rhel) echo bind-utils;;
    net_tools:*) echo net-tools;; iproute:debian) echo iproute2;; iproute:rhel) echo iproute;;
    ping:debian) echo iputils-ping;; ping:rhel) echo iputils;;
    netcat:debian) echo netcat-openbsd;; netcat:rhel) echo nmap-ncat;;
    openssh_client:debian) echo openssh-client;; openssh_client:rhel) echo openssh-clients;;
    openssh_server:debian) echo openssh-server;; openssh_server:rhel) echo openssh-server;;
    mtr:debian) echo mtr-tiny;; mtr:rhel) echo mtr;;
    cifs_utils:*) echo cifs-utils;; smbclient:debian) echo smbclient;; smbclient:rhel) echo samba-client;;
    nfs_client:debian) echo nfs-common;; nfs_client:rhel) echo nfs-utils;;
    sensors:debian) echo lm-sensors;; sensors:rhel) echo lm_sensors;;
    procps:debian) echo procps;; procps:rhel) echo procps-ng;;
    docker_engine:*|ohmyzsh:*|zsh_default:*|lsd_aliases:*) echo "";;
    *) echo "$app";;
  esac
}

term_cleanup(){ printf '\033[?25h'; stty echo 2>/dev/null || true; }
trap term_cleanup EXIT INT TERM
read_key(){
  local key rest
  IFS= read -rsn1 key || true
  if [[ "$key" == $'\e' ]]; then
    IFS= read -rsn2 -t 0.08 rest || true
    key+="$rest"
  fi
  REPLY="$key"
}
checkbox(){ [[ "$1" == true ]] && printf '%b' "${GREEN}[x]${NC}" || printf '[ ]'; }
profile_state(){
  local p="$1" app on=0 total=0
  for app in ${PROFILE_APPS[$p]}; do ((total+=1)); [[ "${APP_SELECTED[$app]:-false}" == true ]] && ((on+=1)); done
  if ((on == total)); then printf '%b' "${GREEN}[x]${NC}"; elif ((on > 0)); then printf '%b' "${YELLOW}[-]${NC}"; else printf '[ ]'; fi
}

render_main(){
  local cursor="$1" i=0 p line
  clear
  printf '%b\n' "${CYAN}${BOLD}============================================================${NC}"
  printf '%b\n' "${CYAN}${BOLD}              HOMELAB LINUX BOOTSTRAP v${VERSION}${NC}"
  printf '%b\n\n' "${CYAN}${BOLD}============================================================${NC}"
  printf '%-17s %s\n' "OS:" "$DISTRO_NAME" "Platform:" "$PLATFORM" "Package family:" "$FAMILY" "Target user:" "$TARGET_USER"
  printf '\n%b\n' "${BOLD}Profiles${NC}  ${DIM}(Recommended is preselected)${NC}"
  for p in "${PROFILE_ORDER[@]}"; do
    line="$(profile_state "$p")  ${PROFILE_LABEL[$p]}"
    if ((i == cursor)); then printf '%b\n' "${REV}> $line${NC}"; else printf '  %b\n' "$line"; fi
    ((i+=1))
  done
  local actions=("Customize individual applications" "Apply Recommended preset" "Select everything" "Clear selections" "Install selected items" "Quit")
  printf '\n%b\n' "${BOLD}Actions${NC}"
  for line in "${actions[@]}"; do
    if ((i == cursor)); then printf '%b\n' "${REV}> $line${NC}"; else printf '  %s\n' "$line"; fi
    ((i+=1))
  done
  printf '\n%s\n' "Use Up/Down or J/K to navigate. Space toggles. Enter selects. Q quits."
}

toggle_profile(){
  local p="$1" new=true
  [[ "${PROFILE_SELECTED[$p]}" == true ]] && new=false
  PROFILE_SELECTED[$p]="$new"
  local app; for app in ${PROFILE_APPS[$p]}; do APP_SELECTED[$app]="$new"; unset 'APP_OVERRIDE[$app]'; done
}

profile_app_menu(){
  local pcursor=0 pcount=${#PROFILE_ORDER[@]} key p
  while true; do
    clear; printf '%b\n\n' "${CYAN}${BOLD}Choose a profile to customize${NC}"
    for ((i=0;i<pcount;i++)); do p="${PROFILE_ORDER[$i]}"; if ((i==pcursor)); then printf '%b\n' "${REV}> $(profile_state "$p") ${PROFILE_LABEL[$p]}${NC}"; else printf '  %b %s\n' "$(profile_state "$p")" "${PROFILE_LABEL[$p]}"; fi; done
    printf '\n%s\n' "Enter opens apps. Esc or Q returns."
    read_key; key="$REPLY"
    case "$key" in $'\e[A'|k|K) ((pcursor=(pcursor-1+pcount)%pcount));; $'\e[B'|j|J) ((pcursor=(pcursor+1)%pcount));; ""|$'\n') app_menu "${PROFILE_ORDER[$pcursor]}";; q|Q|$'\e') return;; esac
  done
}

app_menu(){
  local p="$1" apps_string="${PROFILE_APPS[$p]}" key cursor=0 app count i on total
  read -r -a apps <<< "$apps_string"; count=${#apps[@]}
  while true; do
    clear; printf '%b\n' "${CYAN}${BOLD}${PROFILE_LABEL[$p]}: individual applications${NC}"
    printf '%s\n\n' "Space toggles one item. A selects all. C clears. Enter/Esc returns."
    for ((i=0;i<count;i++)); do
      app="${apps[$i]}"; line="$(checkbox "${APP_SELECTED[$app]:-false}")  ${APP_LABEL[$app]}"
      if ((i==cursor)); then printf '%b\n' "${REV}> $line${NC}"; else printf '  %b\n' "$line"; fi
    done
    read_key; key="$REPLY"
    case "$key" in
      $'\e[A'|k|K) ((cursor=(cursor-1+count)%count));;
      $'\e[B'|j|J) ((cursor=(cursor+1)%count));;
      ' ')
        app="${apps[$cursor]}"; [[ "${APP_SELECTED[$app]:-false}" == true ]] && APP_SELECTED[$app]=false || APP_SELECTED[$app]=true
        APP_OVERRIDE[$app]=true;;
      a|A) for app in "${apps[@]}"; do APP_SELECTED[$app]=true; APP_OVERRIDE[$app]=true; done;;
      c|C) for app in "${apps[@]}"; do APP_SELECTED[$app]=false; APP_OVERRIDE[$app]=true; done;;
      ""|$'\n'|q|Q|$'\e')
        on=0; total=${#apps[@]}; for app in "${apps[@]}"; do [[ "${APP_SELECTED[$app]:-false}" == true ]] && ((on+=1)); done
        ((on > 0)) && PROFILE_SELECTED[$p]=true || PROFILE_SELECTED[$p]=false
        return;;
    esac
  done
}

selected_count(){ local app n=0; for app in "${!APP_SELECTED[@]}"; do [[ "${APP_SELECTED[$app]}" == true ]] && ((n+=1)); done; echo "$n"; }
confirm_install(){
  local app count; count="$(selected_count)"
  if ((count == 0)); then warn "Nothing is selected. Choose at least one application."; sleep 2; return 1; fi
  clear; printf '%b\n\n' "${CYAN}${BOLD}Installation summary${NC}"
  printf '%s\n' "Selected items: $count" "Platform: $PLATFORM" "Target user: $TARGET_USER"
  if [[ "$VIRT_TYPE" == lxc && "${APP_SELECTED[docker_engine]:-false}" == true ]]; then
    printf '\n%b\n' "${YELLOW}Warning: Docker in an LXC generally requires nesting to be enabled on the Proxmox host.${NC}"
  fi
  printf '\n%s' "Continue installation? [y/N]: "
  local answer; read -r answer; [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

interactive_menu(){
  local cursor=0 total=$((${#PROFILE_ORDER[@]}+6)) key pidx
  while true; do
    render_main "$cursor"; read_key; key="$REPLY"
    case "$key" in
      $'\e[A'|k|K) ((cursor=(cursor-1+total)%total));;
      $'\e[B'|j|J) ((cursor=(cursor+1)%total));;
      ' ')
        if ((cursor<${#PROFILE_ORDER[@]})); then toggle_profile "${PROFILE_ORDER[$cursor]}"; fi;;
      q|Q) exit 0;;
      ""|$'\n')
        if ((cursor<${#PROFILE_ORDER[@]})); then toggle_profile "${PROFILE_ORDER[$cursor]}"; continue; fi
        pidx=$((cursor-${#PROFILE_ORDER[@]}))
        case "$pidx" in
          0) profile_app_menu;; 1) clear_all; select_recommended;; 2) clear_all; select_all;;
          3) clear_all;; 4) confirm_install && return;; 5) exit 0;;
        esac;;
      *) ;; # Invalid keys are safely ignored.
    esac
  done
}

usage(){ cat <<EOF
Usage: sudo $0 [--recommended|--all|profile flags]
Profiles: --core --network --storage --smb --docker --monitoring --shell
Other: --recommended --all --yes --list --help
No arguments opens the keyboard-driven interactive menu.
EOF
}
NONINTERACTIVE=false; ASSUME_YES=false
parse_args(){
  clear_all; NONINTERACTIVE=true
  while (($#)); do
    case "$1" in
      --core) set_profile core true;; --network) set_profile network true;; --storage) set_profile storage true;;
      --smb) set_profile smb true;; --docker) set_profile docker true;; --monitoring) set_profile monitoring true;;
      --shell) set_profile shell true;; --recommended) select_recommended;; --all) select_all;; --yes|-y) ASSUME_YES=true;;
      --list) for p in "${PROFILE_ORDER[@]}"; do echo "$p - ${PROFILE_LABEL[$p]}"; done; exit 0;;
      --help|-h) usage; exit 0;; *) fail "Unknown option: $1"; usage; exit 1;;
    esac; shift
  done
  (($(selected_count)>0)) || { fail "No applications selected."; exit 1; }
}

update_metadata(){ if [[ "$FAMILY" == debian ]]; then export DEBIAN_FRONTEND=noninteractive; apt-get update; else dnf makecache -y; fi; }
package_available(){ if [[ "$FAMILY" == debian ]]; then apt-cache show "$1" >/dev/null 2>&1; else dnf -q list --available "$1" >/dev/null 2>&1 || rpm -q "$1" >/dev/null 2>&1; fi; }
install_selected_packages(){
  local app pkg packages=() seen=" "
  for app in "${!APP_SELECTED[@]}"; do
    [[ "${APP_SELECTED[$app]}" == true ]] || continue
    pkg="$(package_name "$app")"; [[ -n "$pkg" ]] || continue
    [[ "$seen" == *" $pkg "* ]] && continue
    if package_available "$pkg"; then packages+=("$pkg"); seen+="$pkg "; else warn "Package '$pkg' is unavailable; skipped."; fi
  done
  ((${#packages[@]})) || return 0
  info "Installing ${#packages[@]} selected repository packages..."
  [[ "$FAMILY" == debian ]] && apt-get install -y "${packages[@]}" || dnf install -y "${packages[@]}"
}
append_once(){ local line="$1" file="$2"; touch "$file"; grep -Fqx "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"; }
configure_shell(){
  local zrc="$TARGET_HOME/.zshrc" zsh_path="$(command -v zsh 2>/dev/null || true)"
  if [[ "${APP_SELECTED[ohmyzsh]:-false}" == true ]]; then
    [[ "${APP_SELECTED[zsh]:-false}" == true && -n "$zsh_path" ]] || { warn "Oh My Zsh needs Zsh; skipped."; APP_SELECTED[ohmyzsh]=false; }
    if [[ "${APP_SELECTED[ohmyzsh]}" == true && ! -d "$TARGET_HOME/.oh-my-zsh" ]]; then
      info "Installing Oh My Zsh for $TARGET_USER..."
      if [[ "$TARGET_USER" == root ]]; then
        HOME="$TARGET_HOME" RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" -- --unattended
      else
        sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" -- --unattended
      fi
    fi
  fi
  if [[ "${APP_SELECTED[zsh]:-false}" == true ]]; then
    [[ -f "$zrc" ]] || printf '%s\n' 'export ZSH="$HOME/.oh-my-zsh"' 'ZSH_THEME="robbyrussell"' 'plugins=(git)' '[[ -f "$ZSH/oh-my-zsh.sh" ]] && source "$ZSH/oh-my-zsh.sh"' > "$zrc"
    [[ "${APP_SELECTED[fzf]:-false}" == true ]] && append_once '[[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]] && source /usr/share/doc/fzf/examples/key-bindings.zsh' "$zrc"
    [[ "${APP_SELECTED[fzf]:-false}" == true ]] && append_once '[[ -f /usr/share/doc/fzf/examples/completion.zsh ]] && source /usr/share/doc/fzf/examples/completion.zsh' "$zrc"
    if [[ "${APP_SELECTED[lsd_aliases]:-false}" == true ]]; then
      if [[ "${APP_SELECTED[lsd]:-false}" == true ]]; then
        append_once 'alias ls="lsd"' "$zrc"; append_once 'alias ll="lsd -la"' "$zrc"; append_once 'alias la="lsd -A"' "$zrc"
      else warn "lsd aliases selected without lsd; aliases skipped."; fi
    fi
    [[ "${APP_SELECTED[zsh_default]:-false}" == true && -n "$zsh_path" ]] && usermod -s "$zsh_path" "$TARGET_USER"
    chown -R "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$zrc" "$TARGET_HOME/.oh-my-zsh" 2>/dev/null || true
  fi
}
install_docker(){
  [[ "${APP_SELECTED[docker_engine]:-false}" == true ]] || return 0
  if [[ "$VIRT_TYPE" == lxc && "$ASSUME_YES" != true && "$NONINTERACTIVE" == true ]]; then
    read -r -p "Docker selected in LXC. Continue? [y/N]: " ans; [[ "$ans" =~ ^[Yy] ]] || { warn "Docker skipped."; APP_SELECTED[docker_engine]=false; return; }
  fi
  info "Installing Docker Engine and Compose plugin..."
  if [[ "$FAMILY" == debian ]]; then
    apt-get install -y ca-certificates curl gnupg
    apt-get remove -y docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc >/dev/null 2>&1 || true
    install -m 0755 -d /etc/apt/keyrings
    local repo_os="$DISTRO" codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    [[ "$repo_os" == ubuntu || "$repo_os" == debian ]] || repo_os="${DISTRO_LIKE%% *}"
    [[ "$repo_os" == ubuntu || "$repo_os" == debian ]] || { fail "Unable to map Docker repository for $DISTRO."; return 1; }
    curl -fsSL "https://download.docker.com/linux/$repo_os/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$repo_os $codename stable" > /etc/apt/sources.list.d/docker.list
    apt-get update; apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    dnf install -y dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  systemctl enable --now docker >/dev/null 2>&1 || warn "Docker service could not be started."
}
configure_services(){
  if [[ "${APP_SELECTED[openssh_server]:-false}" == true ]]; then systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || warn "SSH service was not enabled."; fi
  if [[ "$VIRT_TYPE" == kvm || "$VIRT_TYPE" == qemu ]]; then
    info "Installing QEMU guest agent for detected VM."; [[ "$FAMILY" == debian ]] && apt-get install -y qemu-guest-agent || dnf install -y qemu-guest-agent
    systemctl enable --now qemu-guest-agent >/dev/null 2>&1 || true
  fi
}

VALIDATION_FAILURES=0
check(){ local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else fail "$label"; ((VALIDATION_FAILURES+=1)); fi; }
validate(){
  printf '\n%b\n' "${BOLD}Final validation${NC}"
  check "Package manager available" bash -c 'command -v apt-get >/dev/null || command -v dnf >/dev/null'
  check "Default route present" ip route get 1.1.1.1
  check "DNS resolution works" getent hosts github.com
  check "HTTPS connectivity works" curl -fsSIL --max-time 10 https://github.com
  local app cmd
  for app in "${!APP_SELECTED[@]}"; do
    [[ "${APP_SELECTED[$app]}" == true ]] || continue
    case "$app" in
      ohmyzsh) check "Oh My Zsh installed" test -d "$TARGET_HOME/.oh-my-zsh";;
      zsh_default) check "Default shell is Zsh" bash -c "getent passwd '$TARGET_USER' | grep -q '$(command -v zsh)$'";;
      lsd_aliases) check "ls=lsd alias configured" grep -Fqx 'alias ls="lsd"' "$TARGET_HOME/.zshrc";;
      docker_engine) check "Docker service active" systemctl is-active --quiet docker; check "Docker Compose available" docker compose version;;
      dns_tools) cmd=dig; check "${APP_LABEL[$app]}" command -v "$cmd";;
      ping) cmd=ping; check "${APP_LABEL[$app]}" command -v "$cmd";;
      openssh_server) cmd=sshd; check "${APP_LABEL[$app]}" command -v "$cmd";;
      sensors) cmd=sensors; check "${APP_LABEL[$app]}" command -v "$cmd";;
      procps) cmd=ps; check "${APP_LABEL[$app]}" command -v "$cmd";;
      bash_completion|ca_certificates|gnupg|net_tools|iproute|openssh_client|cifs_utils|nfs_client) :;;
      *) cmd="$app"; command -v "$cmd" >/dev/null 2>&1 && ok "${APP_LABEL[$app]}" || { fail "${APP_LABEL[$app]}"; ((VALIDATION_FAILURES+=1)); };;
    esac
  done
  ((VALIDATION_FAILURES==0)) && ok "All required checks passed." || warn "$VALIDATION_FAILURES validation check(s) failed."
}
cleanup(){ [[ "$FAMILY" == debian ]] && { apt-get autoremove -y; apt-get clean; } || dnf clean all; }
main(){
  if (($#)); then parse_args "$@"; else interactive_menu; fi
  term_cleanup
  update_metadata
  install_selected_packages
  configure_shell
  install_docker
  configure_services
  cleanup
  validate
  printf '\n%s\n' "Completed for $DISTRO_NAME on $PLATFORM."
  [[ "${APP_SELECTED[zsh_default]:-false}" == true ]] && echo "Log out and back in to start Zsh."
  ((VALIDATION_FAILURES==0))
}
main "$@"
