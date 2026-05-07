RS
export EDITOR=vim
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
alias gs='git status'
alias gl='git log --oneline --graph --decorate --all'
alias psa='ps aux | grep -v grep | grep -i'
alias ve='source .venv/bin/activate'
alias ports='sudo lsof -i -P -n'
alias myip='curl -s ifconfig.me'
alias oom="sudo journalctl -k -o short-iso -q | grep 'Killed process' | sed -E 's/^([0-9-]+ [0-9:]+).*Killed process ([0-9]+) \(([^)]+)\).*total-vm:([0-9]+)kB, anon-rss:([0-9]+)kB.*/\1 | pid:\2 | \3 | vm:\4kB | rss:\5kB/'"

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

