#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_USER="samane"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DO_CREATE_USER=0
DO_APT=0
DO_UV=0
DO_SSH_KEY=0
DO_BASHRC=0
DO_PWRAP=0
DO_NVIM=0
DO_TOOLS=0

usage() {
  cat <<'EOF'
Usage:
  sudo bash bootstrap.sh [options]

Profiles:
  --simple         Create user, install apt tools, uv, SSH key, bashrc settings, uv tools.
                   Does not install pwrap or nvim.

  --ide            Everything in --simple, plus pwrap and nvim.

Individual options:
  --user NAME      Target user. Default: samane.
  --create-user   Create target user with sudo privileges.
  --apt           Install apt helper packages.
  --uv            Install uv for target user.
  --ssh-key       Create ed25519 SSH key for target user, no passphrase.
  --bashrc        Install helper bashrc settings.
  --pwrap         Install pwrap prompt tools.
  --nvim          Install Neovim AppImage and init.vim.
  --tools         Install Python/dev tools via uv.

Other:
  -h, --help      Show this help.
EOF
}

need_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "This script should be run with sudo/root for system setup." >&2
    exit 1
  fi
}

confirm() {
  local message="$1"
  local reply

  printf '%s [y/N] ' "$message"
  read -r reply

  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

home_for_user() {
  getent passwd "$TARGET_USER" | cut -d: -f6
}

run_as_user() {
  local user_home
  user_home="$(home_for_user)"

  sudo -H -u "$TARGET_USER" bash -lc "cd '$user_home' && $*"
}

ensure_user_exists() {
  if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo "User '$TARGET_USER' does not exist." >&2
    echo "Run with --create-user or use --simple / --ide." >&2
    exit 1
  fi
}

create_user() {
  if id "$TARGET_USER" >/dev/null 2>&1; then
    echo "User '$TARGET_USER' already exists."
    usermod -aG sudo "$TARGET_USER"
    return 0
  fi

  if ! confirm "Create user '$TARGET_USER' with sudo privileges?"; then
    echo "Cancelled user creation."
    exit 1
  fi

  adduser --disabled-password --gecos "" "$TARGET_USER"
  usermod -aG sudo "$TARGET_USER"

  echo "Created user '$TARGET_USER' and added to sudo group."
}

install_apt_packages() {
  apt update

  apt install -y \
    curl \
    ca-certificates \
    git \
    sudo \
    ripgrep

  if apt install -y eza; then
    echo "Installed eza."
  else
    echo "Warning: could not install eza via apt. Continuing." >&2
  fi
}

install_uv() {
  ensure_user_exists

  run_as_user '
    set -Eeuo pipefail

    if command -v uv >/dev/null 2>&1; then
      echo "uv already installed: $(command -v uv)"
      uv --version
      exit 0
    fi

    curl -LsSf https://astral.sh/uv/install.sh | sh

    export PATH="$HOME/.local/bin:$PATH"

    if command -v uv >/dev/null 2>&1; then
      uv --version
    else
      echo "uv install completed, but uv is not on PATH yet." >&2
      echo "Try opening a new shell or ensure ~/.local/bin is on PATH." >&2
      exit 1
    fi
  '
}

install_ssh_key() {
  ensure_user_exists

  run_as_user '
    set -Eeuo pipefail

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
      ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -C "$USER@$(hostname)-$(date +%Y%m%d)"
    else
      echo "SSH key already exists: $HOME/.ssh/id_ed25519"
    fi

    eval "$(ssh-agent -s)"
    ssh-add "$HOME/.ssh/id_ed25519"

    echo
    echo "Public key:"
    cat "$HOME/.ssh/id_ed25519.pub"
    echo
  '
}

add_source_block() {
  local bashrc="$1"
  local label="$2"
  local script_path="$3"

  local begin="# >>> helper_scripts: $label >>>"
  local end="# <<< helper_scripts: $label <<<"

  touch "$bashrc"

  if grep -Fq "$begin" "$bashrc"; then
    echo "bashrc source block already present: $label"
    return 0
  fi

  cat >> "$bashrc" <<EOF

$begin
if [[ -f "$script_path" ]]; then
  source "$script_path"
fi
$end
EOF
}

install_bashrc_settings() {
  ensure_user_exists

  local user_home
  user_home="$(home_for_user)"

  install -d -o "$TARGET_USER" -g "$TARGET_USER" "$user_home/.bashrc.d"

  install -m 0644 -o "$TARGET_USER" -g "$TARGET_USER" \
    "$REPO_DIR/files/bashrc.d/helper_settings.sh" \
    "$user_home/.bashrc.d/helper_settings.sh"

  add_source_block \
    "$user_home/.bashrc" \
    "helper_settings" \
    "\$HOME/.bashrc.d/helper_settings.sh"

  chown "$TARGET_USER:$TARGET_USER" "$user_home/.bashrc"

  echo "Installed helper bashrc settings."
}

install_pwrap() {
  ensure_user_exists

  local user_home
  user_home="$(home_for_user)"

  if [[ ! -f "$REPO_DIR/files/bashrc.d/prompt_tools.sh" ]]; then
    echo "Missing file: files/bashrc.d/prompt_tools.sh" >&2
    echo "Put your current pwrap script there first." >&2
    exit 1
  fi

  install -d -o "$TARGET_USER" -g "$TARGET_USER" "$user_home/.bashrc.d"

  install -m 0644 -o "$TARGET_USER" -g "$TARGET_USER" \
    "$REPO_DIR/files/bashrc.d/prompt_tools.sh" \
    "$user_home/.bashrc.d/prompt_tools.sh"

  add_source_block \
    "$user_home/.bashrc" \
    "prompt_tools" \
    "\$HOME/.bashrc.d/prompt_tools.sh"

  chown "$TARGET_USER:$TARGET_USER" "$user_home/.bashrc"

  echo "Installed pwrap prompt tools."
}

install_nvim() {
  ensure_user_exists

  local user_home
  user_home="$(home_for_user)"

  local arch
  arch="$(uname -m)"

  if [[ "$arch" != "x86_64" ]]; then
    echo "This nvim installer currently expects x86_64. Detected: $arch" >&2
    exit 1
  fi

  curl -L -o /tmp/nvim-linux-x86_64.appimage \
    https://github.com/neovim/neovim/releases/download/stable/nvim-linux-x86_64.appimage

  chmod +x /tmp/nvim-linux-x86_64.appimage
  mv /tmp/nvim-linux-x86_64.appimage /usr/local/bin/nvim

  install -d -o "$TARGET_USER" -g "$TARGET_USER" "$user_home/.config/nvim"

  if [[ -f "$REPO_DIR/files/nvim/init.vim" ]]; then
    install -m 0644 -o "$TARGET_USER" -g "$TARGET_USER" \
      "$REPO_DIR/files/nvim/init.vim" \
      "$user_home/.config/nvim/init.vim"
  else
    echo "Warning: files/nvim/init.vim not found. Installed nvim binary only." >&2
  fi

  echo "Installed nvim:"
  nvim --version | head -n 1
}

install_uv_tools() {
  ensure_user_exists

  run_as_user '
    set -Eeuo pipefail

    export PATH="$HOME/.local/bin:$PATH"

    if ! command -v uv >/dev/null 2>&1; then
      echo "uv not found. Run --uv first." >&2
      exit 1
    fi

    uv tool install --with "pyright[nodejs]" pyright
    uv tool install black
    uv tool install ruff
    uv tool install debugpy
    uv tool update-shell

    echo "Installed uv tools."
  '
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      TARGET_USER="${2:-}"
      if [[ -z "$TARGET_USER" ]]; then
        echo "--user requires a value." >&2
        exit 1
      fi
      shift 2
      ;;

    --simple)
      DO_CREATE_USER=1
      DO_APT=1
      DO_UV=1
      DO_SSH_KEY=1
      DO_BASHRC=1
      DO_TOOLS=1
      shift
      ;;

    --ide)
      DO_CREATE_USER=1
      DO_APT=1
      DO_UV=1
      DO_SSH_KEY=1
      DO_BASHRC=1
      DO_TOOLS=1
      DO_PWRAP=1
      DO_NVIM=1
      shift
      ;;

    --create-user)
      DO_CREATE_USER=1
      shift
      ;;

    --apt)
      DO_APT=1
      shift
      ;;

    --uv)
      DO_UV=1
      shift
      ;;

    --ssh-key)
      DO_SSH_KEY=1
      shift
      ;;

    --bashrc)
      DO_BASHRC=1
      shift
      ;;

    --pwrap)
      DO_PWRAP=1
      shift
      ;;

    --nvim)
      DO_NVIM=1
      shift
      ;;

    --tools)
      DO_TOOLS=1
      shift
      ;;

    -h|--help)
      usage
      exit 0
      ;;

    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$DO_CREATE_USER$DO_APT$DO_UV$DO_SSH_KEY$DO_BASHRC$DO_PWRAP$DO_NVIM$DO_TOOLS" == "00000000" ]]; then
  usage
  exit 1
fi

need_root

[[ "$DO_CREATE_USER" -eq 1 ]] && create_user
[[ "$DO_APT" -eq 1 ]] && install_apt_packages
[[ "$DO_UV" -eq 1 ]] && install_uv
[[ "$DO_SSH_KEY" -eq 1 ]] && install_ssh_key
[[ "$DO_BASHRC" -eq 1 ]] && install_bashrc_settings
[[ "$DO_PWRAP" -eq 1 ]] && install_pwrap
[[ "$DO_NVIM" -eq 1 ]] && install_nvim
[[ "$DO_TOOLS" -eq 1 ]] && install_uv_tools

echo
echo "Bootstrap complete for user: $TARGET_USER"
echo "Log in as that user or run:"
echo "  su - $TARGET_USER"
