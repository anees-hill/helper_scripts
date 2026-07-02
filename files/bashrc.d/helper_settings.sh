# VARS
export EDITOR=vim
export PATH="$HOME/.local/bin:$PATH"

# Local private config files
# helper_settings.sh is managed by helper_scripts.
# Put machine-specific extras in ~/.bashrc.d/bash_local.sh.
# Put VisiData database aliases in ~/.bashrc.d/vdb_connections.
#
# Alias'
# General
alias e='nvim'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ls='eza'
alias llh='eza -alh'
alias ll='eza -lF --group'
alias lla='eza -alF --group'
alias la='eza -A'
alias l='eza -CF'
alias lt='eza -lh --sort=modified --reverse --group'
alias lta='eza -lh --sort=modified --group'
alias lt1='eza --sort newest --reverse -l | head -n 1'
alias lt5='eza --sort newest --reverse -l | head -n 5'
alias lt10='eza --sort newest --reverse -l | head -n 10'
alias ltd='eza -lh --sort=size --reverse --group'
alias ltd5='ltd | head -n 5'
alias ltda='eza -lh --sort=size --group'
alias ltda5='ltda | head -n 5'
alias psa='ps aux | grep -v grep | grep -i'
alias ve='source .venv/bin/activate'
alias ports='sudo lsof -i -P -n'
alias myip='curl -s ifconfig.me'
alias oom="sudo journalctl -k -o short-iso -q | grep 'Killed process' | sed -E 's/^([0-9-]+ [0-9:]+).*Killed process ([0-9]+) \(([^)]+)\).*total-vm:([0-9]+)kB, anon-rss:([0-9]+)kB.*/\1 | pid:\2 | \3 | vm:\4kB | rss:\5kB/'"

# git
alias gs='git status'

# Existing-style log
alias gl='git log --oneline --graph --decorate --all'

# gl + absolute commit datetime
alias glt='git log --graph --decorate --all --date=format-local:"%Y-%m-%d %H:%M" --pretty=format:"%C(auto)%h%Creset %C(cyan)%ad%Creset %C(auto)%d%Creset %s"'

# gl + relative commit time, e.g. "4 hours ago"
alias glts='git log --graph --decorate --all --date=relative --pretty=format:"%C(auto)%h%Creset %C(cyan)%ar%Creset %C(auto)%d%Creset %s"'

# gl + author
alias glc='git log --graph --decorate --all --pretty=format:"%C(auto)%h%Creset %C(yellow)%an%Creset %C(auto)%d%Creset %s"'

# gl + absolute datetime + author
alias gltc='git log --graph --decorate --all --date=format-local:"%Y-%m-%d %H:%M" --pretty=format:"%C(auto)%h%Creset %C(cyan)%ad%Creset %C(yellow)%an%Creset %C(auto)%d%Creset %s"'
alias glct='gltc'

# gl + relative time + author
alias gltsc='git log --graph --decorate --all --date=relative --pretty=format:"%C(auto)%h%Creset %C(cyan)%ar%Creset %C(yellow)%an%Creset %C(auto)%d%Creset %s"'
alias glst='gltsc'

# Recent branches
alias gb='git branch --sort=-committerdate --format="%(committerdate:relative) %(refname:short)"'

_git_base_ref() {
  local ref

  for ref in '@{upstream}' origin/HEAD origin/main origin/master main master origin/develop develop; do
    if git rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
      echo "$ref"
      return 0
    fi
  done

  return 1
}

gmb() {
  local base_ref="${1:-}"
  local base_sha=""

  if [[ -z "$base_ref" ]]; then
    base_ref="$(_git_base_ref)" || {
      echo "gmb: could not find upstream/main/master/develop base ref" >&2
      return 1
    }
  fi

  base_sha="$(git merge-base HEAD "$base_ref")" || return 1
  echo "$base_sha"
}

glb() {
  local base_ref="${1:-}"
  local base_sha=""

  if [[ -z "$base_ref" ]]; then
    base_ref="$(_git_base_ref)" || {
      echo "glb: could not find upstream/main/master/develop base ref" >&2
      echo "Usage: glb [base-ref]" >&2
      echo "Example: glb main" >&2
      return 1
    }
  fi

  base_sha="$(git merge-base HEAD "$base_ref")" || return 1

  echo "Branch: $(git branch --show-current)"
  echo "Base:   $base_sha ($base_ref)"
  echo

  git log --oneline --graph --decorate "$base_sha..HEAD"
  echo
  echo "Branched from:"
  git log -1 --oneline --decorate "$base_sha"
}

gshowbase() {
  git show "$(gmb "$@")"
}

gdiffbase() {
  git diff "$(gmb "$@")"..HEAD
}

glogbase() {
  git log --oneline --graph --decorate "$(gmb "$@")"..HEAD
}

# Resource use
alias topcpu='ps -eo pid,%cpu,args --sort=-%cpu | head -n 11'
alias topmem='ps -eo pid,%mem,args --sort=-%mem | head -n 11'
alias topmix='ps -eo pid,%cpu,%mem,args --sort=-%cpu,-%mem | head -n 11'

topcpuavg() {
  local duration="${1:-30}"
  local interval="${2:-2}"
  local loops=$((duration / interval))

  for _ in $(seq 1 "$loops"); do
    ps -eo pid,%cpu,args --no-headers
    sleep "$interval"
  done | awk '
    {
      pid = $1
      cpu = $2
      $1 = ""; $2 = ""
      sub(/^  */, "")
      cmd = $0
      key = pid "\t" cmd
      v[key] += cpu
      c[key] += 1
    }
    END {
      for (k in v) {
        avg = v[k] / c[k]
        split(k, parts, "\t")
        pid = parts[1]
        cmd = parts[2]

        # truncate command to 80 chars
        if (length(cmd) > 80) {
          cmd = substr(cmd, 1, 77) "..."
        }

        printf "%.2f\tpid:%s\t%s\n", avg, pid, cmd
      }
    }
  ' | sort -nr | head -n 10
}

topmemavg() {
  local duration="${1:-30}"
  local interval="${2:-2}"
  local loops=$((duration / interval))

  for _ in $(seq 1 "$loops"); do
    ps -eo pid,%mem,args --no-headers
    sleep "$interval"
  done | awk '
    {
      pid = $1
      mem = $2
      $1 = ""; $2 = ""
      sub(/^  */, "")
      cmd = $0
      key = pid "\t" cmd
      v[key] += mem
      c[key] += 1
    }
    END {
      for (k in v) {
        avg = v[k] / c[k]
        split(k, parts, "\t")
        pid = parts[1]
        cmd = parts[2]

        if (length(cmd) > 80) {
          cmd = substr(cmd, 1, 77) "..."
        }

        printf "%.2f\tpid:%s\t%s\n", avg, pid, cmd
      }
    }
  ' | sort -nr | head -n 10
}
alias diskwrite='sudo iotop -oP'
alias diskwatch='sudo iotop -oP -d 1'
alias iotopn='sudo iotop -b -n 1 -o'
alias iowait='top -o %wa'
alias diskstat='iostat -xz 1'

_recent_file() {
  local n="${1:-1}"
  eza --sort newest --reverse -1 | sed -n "${n}p"
}

# Shell fns
vdb() {
  local db_alias="${1:-}"
  local schema="${2:-}"
  local conn_file="$HOME/.bashrc.d/vdb_connections"
  local conn_string=""

  if [[ -z "$db_alias" || -z "$schema" ]]; then
    echo "Usage: vdb DATABASE_ALIAS SCHEMA" >&2
    echo "Example: vdb OPERA_PROD trf" >&2
    return 1
  fi

  if ! command -v vd >/dev/null 2>&1; then
    echo "vdb: vd command not found. Install with:" >&2
    echo "  sudo bash bootstrap.sh --visidata" >&2
    return 1
  fi

  if ! [[ "$db_alias" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "vdb: invalid database alias: $db_alias" >&2
    return 1
  fi

  if [[ ! -f "$conn_file" ]]; then
    echo "vdb: connection file not found: $conn_file" >&2
    echo "Create it with entries like:" >&2
    echo "  OPERA_PROD='postgres://user:password@host:5432/database'" >&2
    return 1
  fi

  # shellcheck source=/dev/null
  source "$conn_file"

  conn_string="${!db_alias:-}"

  if [[ -z "$conn_string" ]]; then
    echo "vdb: no connection string found for alias: $db_alias" >&2
    echo "Edit: $conn_file" >&2
    echo "Expected something like:" >&2
    echo "  ${db_alias}='postgres://user:password@host:5432/database'" >&2
    return 1
  fi

  vd --postgres-schema="$schema" "$conn_string"
}


ltc() {
  local file=$(_recent_file "$1")
  [ -n "$file" ] && cat "$file"
}

ltcs() {
  local file=$(_recent_file "$1")
  [ -n "$file" ] && sudo cat "$file"
}
ltn() {
  local file=$(_recent_file "$1")
  [ -n "$file" ] && nano "$file"
}

ltns() {
  local file=$(_recent_file "$1")
  [ -n "$file" ] && sudo nano "$file"
}
ltv() {
  local file=$(_recent_file "$1")
  [ -n "$file" ] && vim "$file"
}

ltvs() {
  local file=$(_recent_file "$1")
  [ -n "$file" ] && sudo vim "$file"
}
ltf() {
  local file=$(_recent_file "$1")
  [ -n "$file" ] && tail -f "$file"
}

ltfs() {
  local file=$(_recent_file "$1")
  [ -n "$file" ] && sudo tail -f "$file"
}

# --- Loop runners ---
loop-run() {
    local interval="$1"
    shift
    while true; do
        clear
        "$@"
        echo
        sleep "$interval"
    done
}

_lt_latest5() {
    eza --sort newest --reverse -l | head -n 5
}
ltw1()  { loop-run 1  _lt_latest5; }
ltw2()  { loop-run 2  _lt_latest5; }
ltw3()  { loop-run 3  _lt_latest5; }
ltw4()  { loop-run 4  _lt_latest5; }
ltw5()  { loop-run 5  _lt_latest5; }
ltw10() { loop-run 10 _lt_latest5; }
ltw30() { loop-run 30 _lt_latest5; }
ltw60() { loop-run 60 _lt_latest5; }
alias ltw="ltw1"

# Load local shell customisations last.
# This file is intentionally not managed by helper_scripts after creation.
if [[ -f "$HOME/.bashrc.d/bash_local.sh" ]]; then
  source "$HOME/.bashrc.d/bash_local.sh"
fi
