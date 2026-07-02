#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_USER="samane"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DO_CREATE_USER=0
DO_APT=0
DO_UV=0
DO_SSH_KEY=0
DO_BASHRC=0
DO_CORE=0
DO_PWRAP=0
DO_PSYNC=0
DO_APICURL=0
DO_NVIM=0
DO_TOOLS=0
DO_TMUX=0
DO_VISIDATA=0

usage() {
  cat <<'EOF'
Usage:
  sudo bash bootstrap.sh [options]

Profiles:
  --simple         Create user, install apt tools, uv, SSH key, core helpers, bashrc settings, uv tools.
                   Does not install pwrap or nvim.

  --ide            Everything in --simple, plus pwrap, nvim, tmux, apicurl, core helpers and Visidata.

Individual options:
  --user NAME      Target user. Default: samane.
  --create-user   Create target user with sudo privileges.
  --apt           Install apt helper packages.
  --uv            Install uv for target user.
  --ssh-key       Create ed25519 SSH key for target user, no passphrase.
  --bashrc        Install helper bashrc settings.
  --core          Install pver, pregister and pupdate.
  --pwrap         Install pwrap prompt tools.
  --psync         Install psync rsync schedule helper.
  --apicurl       Install apicurl OpenAPI curl scratchpad generator.
  --nvim          Install Neovim AppImage and init.vim.
  --tool         Install Python/dev tools via uv.
  --tmux          Install tmux and populate ~/.tmux.conf.
  --visidata     Install VisiData with PostgreSQL support.

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

helper_config_dir_for_user() {
  local user_home
  user_home="$(home_for_user)"
  printf '%s/.config/helper_scripts' "$user_home"
}

helper_manifest_for_user() {
  printf '%s/install.json' "$(helper_config_dir_for_user)"
}

helper_version() {
  if [[ -f "$REPO_DIR/VERSION" ]]; then
    tr -d '\r\n' < "$REPO_DIR/VERSION"
  else
    printf 'unknown'
  fi
}

record_component() {
  local component="$1"

  ensure_user_exists

  local user_home config_dir manifest version
  user_home="$(home_for_user)"
  config_dir="$(helper_config_dir_for_user)"
  manifest="$(helper_manifest_for_user)"
  version="$(helper_version)"

  install -d -o "$TARGET_USER" -g "$TARGET_USER" "$config_dir"

  sudo -H -u "$TARGET_USER" python3 - "$manifest" "$REPO_DIR" "$version" "$component" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

manifest = Path(sys.argv[1])
repo_dir = sys.argv[2]
version = sys.argv[3]
component = sys.argv[4]

now = datetime.now(timezone.utc).isoformat(timespec="seconds")

if manifest.exists():
    data = json.loads(manifest.read_text(encoding="utf-8"))
else:
    data = {
        "installed_at": now,
        "components": {},
    }

data["repo_dir"] = repo_dir
data["version"] = version
data["user"] = os.environ.get("USER")
data["updated_at"] = now
data.setdefault("installed_at", now)
data.setdefault("components", {})
data["components"][component] = True

manifest.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY

  chown "$TARGET_USER:$TARGET_USER" "$manifest"
}

install_core() {
  ensure_user_exists

  local user_home
  user_home="$(home_for_user)"

  if [[ ! -f "$REPO_DIR/files/bin/pver" ]]; then
    echo "Missing file: files/bin/pver" >&2
    exit 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    apt update
    apt install -y python3
  fi

  install -d -o "$TARGET_USER" -g "$TARGET_USER" "$user_home/.local/bin"

  install -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" \
    "$REPO_DIR/files/bin/pver" \
    "$user_home/.local/bin/pver"

  sed -i 's/\r$//' "$user_home/.local/bin/pver"

  local cmd
  for cmd in pregister pupdate; do
    ln -sf "$user_home/.local/bin/pver" "$user_home/.local/bin/$cmd"
    chown -h "$TARGET_USER:$TARGET_USER" "$user_home/.local/bin/$cmd" 2>/dev/null || true
  done

  record_component "core"

  echo "Installed helper_scripts core commands:"
  echo "  pver"
  echo "  pregister"
  echo "  pupdate"
}

install_apt_packages() {
  apt update

  apt install -y \
    curl \
    ca-certificates \
    git \
    sudo \
    ripgrep \
    rsync \
    python3

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

  if [[ ! -f "$user_home/.bashrc.d/bash_local.sh" ]]; then
    cat > "$user_home/.bashrc.d/bash_local.sh" <<'EOF'
# ~/.bashrc.d/bash_local.sh
# Local shell customisations.
# This file is created by helper_scripts but not overwritten.
EOF

    chown "$TARGET_USER:$TARGET_USER" "$user_home/.bashrc.d/bash_local.sh"
    chmod 0644 "$user_home/.bashrc.d/bash_local.sh"
  fi

  if [[ ! -f "$user_home/.bashrc.d/vdb_connections" ]]; then
    cat > "$user_home/.bashrc.d/vdb_connections" <<'EOF'
# ~/.bashrc.d/vdb_connections
# Local VisiData PostgreSQL connection aliases.
# This file is private/local and should not be committed to Git.
#
# Example:
# MYDB='postgres://user:password@IP:5432/mydbname'
EOF

    chown "$TARGET_USER:$TARGET_USER" "$user_home/.bashrc.d/vdb_connections"
    chmod 0600 "$user_home/.bashrc.d/vdb_connections"
  fi

  add_source_block \
    "$user_home/.bashrc" \
    "helper_settings" \
    "\$HOME/.bashrc.d/helper_settings.sh"

  chown "$TARGET_USER:$TARGET_USER" "$user_home/.bashrc"

  record_component "bashrc"

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

  record_component "pwrap"

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

  if [[ -f "$user_home/.config/nvim/init.vim" ]]; then
    sed -i 's/\r$//' "$user_home/.config/nvim/init.vim"
  fi

  sudo -H -u "$TARGET_USER" bash -lc '
    set -Eeuo pipefail

    curl -fLo "${XDG_DATA_HOME:-$HOME/.local/share}"/nvim/site/autoload/plug.vim --create-dirs \
      https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
  '

  record_component "nvim"

  echo "Installed nvim:"
  nvim --version | head -n 1
}

install_tmux() {
  ensure_user_exists

  local user_home
  user_home="$(home_for_user)"

  if ! command -v tmux >/dev/null 2>&1; then
    apt update
    apt install -y tmux
  else
    echo "tmux already installed: $(command -v tmux)"
  fi

  if ! command -v git >/dev/null 2>&1; then
    apt update
    apt install -y git
  fi

  if [[ ! -f "$REPO_DIR/files/tmux/tmux.conf" ]]; then
    echo "Missing file: files/tmux/tmux.conf" >&2
    echo "Put your .tmux.conf there first." >&2
    exit 1
  fi

  install -d -o "$TARGET_USER" -g "$TARGET_USER" \
    "$user_home/.tmux/plugins" \
    "$user_home/.tmux/resurrect"

  install -m 0644 -o "$TARGET_USER" -g "$TARGET_USER" \
    "$REPO_DIR/files/tmux/tmux.conf" \
    "$user_home/.tmux.conf"

  sed -i 's/\r$//' "$user_home/.tmux.conf"

  run_as_user '
    set -Eeuo pipefail

    mkdir -p "$HOME/.tmux/plugins" "$HOME/.tmux/resurrect"

    if [[ ! -d "$HOME/.tmux/plugins/tpm/.git" ]]; then
      git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
    else
      git -C "$HOME/.tmux/plugins/tpm" pull --ff-only || true
    fi

    if [[ -x "$HOME/.tmux/plugins/tpm/bin/install_plugins" ]]; then
      "$HOME/.tmux/plugins/tpm/bin/install_plugins" || true
    fi
  '

  record_component "tmux"

  echo "Installed tmux config for $TARGET_USER:"
  echo "  $user_home/.tmux.conf"
  echo
  echo "Installed TPM:"
  echo "  $user_home/.tmux/plugins/tpm"
  echo
  echo "After updating an existing tmux session, run:"
  echo "  tmux source-file ~/.tmux.conf"
  echo
  echo "For a clean reload:"
  echo "  tmux kill-server"
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
    record_component "tools"
}

install_psync() {
  ensure_user_exists

  local user_home
  user_home="$(home_for_user)"

  local psync_app_dir
  psync_app_dir="$user_home/.local/share/helper_scripts/psync"

  if [[ ! -f "$REPO_DIR/files/bin/psync" ]]; then
    echo "Missing file: files/bin/psync" >&2
    echo "Put the psync script there first." >&2
    exit 1
  fi

  if ! command -v rsync >/dev/null 2>&1; then
    apt update
    apt install -y rsync
  fi

  install -d -o "$TARGET_USER" -g "$TARGET_USER" \
    "$user_home/.local/bin" \
    "$psync_app_dir"

  install -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" \
    "$REPO_DIR/files/bin/psync" \
    "$psync_app_dir/psync"

  sed -i 's/\r$//' "$psync_app_dir/psync"

  run_as_user '
    set -Eeuo pipefail

    export PATH="$HOME/.local/bin:$PATH"

    if ! command -v uv >/dev/null 2>&1; then
      echo "uv not found. Run bootstrap with --uv first, or use --simple before --psync." >&2
      exit 1
    fi

    uv python install 3.11
    uv venv --python 3.11 "$HOME/.local/share/helper_scripts/psync/.venv"

    "$HOME/.local/share/helper_scripts/psync/.venv/bin/python" --version
  '

  cat > "$user_home/.local/bin/psync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export PSYNC_COMMAND_NAME="$(basename "$0")"

exec "$HOME/.local/share/helper_scripts/psync/.venv/bin/python" \
  "$HOME/.local/share/helper_scripts/psync/psync" "$@"
EOF

  chown "$TARGET_USER:$TARGET_USER" "$user_home/.local/bin/psync"
  chmod 0755 "$user_home/.local/bin/psync"

  local cmd
  for cmd in \
    psync_start \
    psync_stop \
    psync_status \
    psync_adjust \
    psync_now \
    psync_log \
    psync_remove \
    psync_host \
    psync_internal_scheduler
  do
    ln -sf "$user_home/.local/bin/psync" "$user_home/.local/bin/$cmd"
    chown -h "$TARGET_USER:$TARGET_USER" "$user_home/.local/bin/$cmd" 2>/dev/null || true
  done

  record_component "psync"

  echo "Installed psync commands to $user_home/.local/bin"
  echo "Real psync script:"
  echo "  $psync_app_dir/psync"
  echo "Python:"
  echo "  $psync_app_dir/.venv/bin/python"
  echo "Start the scheduler as $TARGET_USER with:"
  echo "  psync_start"
}

install_apicurl() {
  ensure_user_exists

  local user_home
  user_home="$(home_for_user)"

  local apicurl_app_dir
  apicurl_app_dir="$user_home/.local/share/helper_scripts/apicurl"

  if [[ ! -f "$REPO_DIR/files/bin/apicurl.py" ]]; then
    echo "Missing file: files/bin/apicurl.py" >&2
    exit 1
  fi

  install -d -o "$TARGET_USER" -g "$TARGET_USER" \
    "$user_home/.local/bin" \
    "$apicurl_app_dir"

  install -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" \
    "$REPO_DIR/files/bin/apicurl.py" \
    "$apicurl_app_dir/apicurl.py"

  sed -i 's/\r$//' "$apicurl_app_dir/apicurl.py"

  run_as_user '
    set -Eeuo pipefail

    export PATH="$HOME/.local/bin:$PATH"

    if ! command -v uv >/dev/null 2>&1; then
      echo "uv not found. Run bootstrap with --uv first, or use --ide." >&2
      exit 1
    fi

    uv python install 3.11
    uv run python "$HOME/.local/share/helper_scripts/apicurl/apicurl.py" --help >/dev/null
  '

  cat > "$user_home/.local/bin/apicurl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

exec uv run python "$HOME/.local/share/helper_scripts/apicurl/apicurl.py" "$@"
EOF

  chown "$TARGET_USER:$TARGET_USER" "$user_home/.local/bin/apicurl"
  chmod 0755 "$user_home/.local/bin/apicurl"

  record_component "apicurl"

  echo "Installed apicurl:"
  echo "  $user_home/.local/bin/apicurl"
  echo "Real script:"
  echo "  $apicurl_app_dir/apicurl.py"
}

install_visidata() {
  ensure_user_exists

  run_as_user '
    set -Eeuo pipefail

    export PATH="$HOME/.local/bin:$PATH"

    if ! command -v uv >/dev/null 2>&1; then
      echo "uv not found. Run --uv first." >&2
      exit 1
    fi

    uv tool install --with psycopg2-binary visidata
    uv tool update-shell

    if command -v vd >/dev/null 2>&1; then
      echo "Installed VisiData with PostgreSQL support:"
      vd --version
    else
      echo "VisiData installed, but vd is not currently on PATH." >&2
      echo "Open a new shell, or check that ~/.local/bin is on PATH." >&2
    fi
  '
  record_component "visidata"
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
      DO_CORE=1
      DO_TOOLS=1
      shift
      ;;

    --ide)
      DO_CREATE_USER=1
      DO_APT=1
      DO_UV=1
      DO_SSH_KEY=1
      DO_BASHRC=1
      DO_CORE=1
      DO_TOOLS=1
      DO_PWRAP=1
      DO_APICURL=1
      DO_NVIM=1
      DO_TMUX=1
      DO_VISIDATA=1
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

    --core)
      DO_CORE=1
      shift
      ;;

    --pwrap)
      DO_PWRAP=1
      shift
      ;;

    --psync)
      DO_PSYNC=1
      shift
      ;;

    --apicurl)
      DO_APICURL=1
      shift
      ;;

    --nvim)
      DO_NVIM=1
      shift
      ;;

    --tmux)
      DO_TMUX=1
      shift
      ;;

    --tools)
      DO_TOOLS=1
      shift
      ;;

    --visidata)
      DO_VISIDATA=1
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

if (( DO_CREATE_USER + DO_APT + DO_UV + DO_SSH_KEY + DO_BASHRC + DO_CORE + DO_PWRAP + DO_PSYNC + DO_APICURL + DO_NVIM + DO_TOOLS + DO_TMUX + DO_VISIDATA == 0 )); then
  usage
  exit 1
fi

need_root

[[ "$DO_CREATE_USER" -eq 1 ]] && create_user
[[ "$DO_APT" -eq 1 ]] && install_apt_packages
[[ "$DO_UV" -eq 1 ]] && install_uv
[[ "$DO_SSH_KEY" -eq 1 ]] && install_ssh_key
[[ "$DO_BASHRC" -eq 1 ]] && install_bashrc_settings
[[ "$DO_CORE" -eq 1 ]] && install_core
[[ "$DO_PWRAP" -eq 1 ]] && install_pwrap
[[ "$DO_PSYNC" -eq 1 ]] && install_psync
[[ "$DO_APICURL" -eq 1 ]] && install_apicurl
[[ "$DO_NVIM" -eq 1 ]] && install_nvim
[[ "$DO_TMUX" -eq 1 ]] && install_tmux
[[ "$DO_TOOLS" -eq 1 ]] && install_uv_tools
[[ "$DO_VISIDATA" -eq 1 ]] && install_visidata

echo
echo "Bootstrap complete for user: $TARGET_USER"
echo "Log in as that user or run:"
echo "  su - $TARGET_USER"
