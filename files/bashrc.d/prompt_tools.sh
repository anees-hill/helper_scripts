# ~/.bashrc.d/prompt_tools.sh
# Helpers for building ~/.prompt.xml for ChatGPT/code review prompts.

export PROMPT_XML_FILE="${PROMPT_XML_FILE:-$HOME/.prompt.xml}"
export PROMPT_TOOLS_DIR="${PROMPT_TOOLS_DIR:-$HOME/.bashrc.d}"
export PROMPT_LAST_TRUNCATE_FILE="${PROMPT_LAST_TRUNCATE_FILE:-$PROMPT_TOOLS_DIR/last_truncate}"
export PSERVE_DIR="${PSERVE_DIR:-$PROMPT_TOOLS_DIR/pserve}"
export PSERVE_PID_FILE="${PSERVE_PID_FILE:-$PSERVE_DIR/pserve.pid}"
export PSERVE_LOG_FILE="${PSERVE_LOG_FILE:-$PSERVE_DIR/pserve.log}"

ptrunc() {
  _pbackup_then_truncate
}

prestore() {
  _pensure

  if [[ ! -f "$PROMPT_LAST_TRUNCATE_FILE" ]]; then
    echo "prestore: no last truncate file found: $PROMPT_LAST_TRUNCATE_FILE" >&2
    return 1
  fi

  if [[ ! -s "$PROMPT_LAST_TRUNCATE_FILE" ]]; then
    echo "prestore: last truncate file exists but is empty." >&2
    return 1
  fi

  cat "$PROMPT_LAST_TRUNCATE_FILE" >> "$PROMPT_XML_FILE"
  echo "Restored last truncate into $PROMPT_XML_FILE"
}

pw() {
  local slot="${1:-w}"
  local memory_file

  _pensure
  memory_file="$(_pmemory_file "$slot")" || return 1

  cp "$PROMPT_XML_FILE" "$memory_file"
  echo "Saved $PROMPT_XML_FILE to $memory_file"
}

p_recall() {
  local slot="${1:-w}"
  local memory_file

  _pensure
  memory_file="$(_pmemory_file "$slot")" || return 1

  if [[ ! -f "$memory_file" ]]; then
    echo "p@: no memory file found: $memory_file" >&2
    return 1
  fi

  if [[ ! -s "$memory_file" ]]; then
    echo "p@: memory file exists but is empty: $memory_file" >&2
    return 1
  fi

  cat "$memory_file" >> "$PROMPT_XML_FILE"
  echo "Appended $memory_file into $PROMPT_XML_FILE"
}

alias p@='p_recall'

pD() {
  local found=0

  mkdir -p "$PROMPT_TOOLS_DIR"

  if compgen -G "$PROMPT_TOOLS_DIR/memory_*" >/dev/null; then
    found=1
  fi

  if [[ -e "$PROMPT_LAST_TRUNCATE_FILE" ]]; then
    found=1
  fi

  if [[ "$found" -eq 0 ]]; then
    echo "pD: no memory files or last_truncate file found."
    return 0
  fi

  echo "This will delete:"
  ls -1 "$PROMPT_TOOLS_DIR"/memory_* 2>/dev/null
  [[ -e "$PROMPT_LAST_TRUNCATE_FILE" ]] && echo "$PROMPT_LAST_TRUNCATE_FILE"
  printf 'Continue? [y/N] '

  local reply
  read -r reply

  case "$reply" in
    y|Y|yes|YES)
      rm -f "$PROMPT_TOOLS_DIR"/memory_* "$PROMPT_LAST_TRUNCATE_FILE"
      echo "Deleted prompt memory files and last_truncate."
      ;;
    *)
      echo "Cancelled."
      return 1
      ;;
  esac
}

psize() {
  _pensure
  du -k "$PROMPT_XML_FILE" | cut -f1
}

popen() {
  _pensure
  nvim "$PROMPT_XML_FILE"
}

pcat() {
  _pensure
  cat "$PROMPT_XML_FILE"
}

phead() {
  _pensure
  head -n "${1:-80}" "$PROMPT_XML_FILE"
}

ptail() {
  _pensure
  tail -n "${1:-80}" "$PROMPT_XML_FILE"
}

pcopy() {
  _pensure

  if command -v wl-copy >/dev/null 2>&1; then
    wl-copy < "$PROMPT_XML_FILE"
    echo "Copied $(du -k "$PROMPT_XML_FILE" | cut -f1) KB using wl-copy."
    return 0
  fi

  if command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard < "$PROMPT_XML_FILE"
    echo "Copied $(du -k "$PROMPT_XML_FILE" | cut -f1) KB using xclip."
    return 0
  fi

  if command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --input < "$PROMPT_XML_FILE"
    echo "Copied $(du -k "$PROMPT_XML_FILE" | cut -f1) KB using xsel."
    return 0
  fi

  if command -v clip.exe >/dev/null 2>&1; then
    clip.exe < "$PROMPT_XML_FILE"
    echo "Copied $(du -k "$PROMPT_XML_FILE" | cut -f1) KB using clip.exe."
    return 0
  fi

  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "Set-Clipboard -Raw -Value ([Console]::In.ReadToEnd())" < "$PROMPT_XML_FILE"
    echo "Copied $(du -k "$PROMPT_XML_FILE" | cut -f1) KB using PowerShell Set-Clipboard."
    return 0
  fi

  if command -v pbcopy >/dev/null 2>&1; then
    pbcopy < "$PROMPT_XML_FILE"
    echo "Copied $(du -k "$PROMPT_XML_FILE" | cut -f1) KB using pbcopy."
    return 0
  fi

  if _pcopy_osc52 "$PROMPT_XML_FILE"; then
    echo "Copied $(du -k "$PROMPT_XML_FILE" | cut -f1) KB using OSC52 terminal clipboard."
    return 0
  fi

  echo "pcopy: no clipboard tool found." >&2
  echo "Install one of: wl-clipboard, xclip, xsel." >&2
  echo "For SSH-to-local clipboard, use a terminal that supports OSC52." >&2
  return 1
}

_pensure() {
  mkdir -p "$(dirname "$PROMPT_XML_FILE")"
  mkdir -p "$PROMPT_TOOLS_DIR"
  touch "$PROMPT_XML_FILE"
}

_pbackup_then_truncate() {
  _pensure

  : > "$PROMPT_LAST_TRUNCATE_FILE"
  cat "$PROMPT_XML_FILE" > "$PROMPT_LAST_TRUNCATE_FILE"
  : > "$PROMPT_XML_FILE"

}

_pmemory_file() {
  local slot="$1"

  if [[ -z "$slot" ]]; then
    slot="w"
  fi

  if [[ "$slot" =~ [/] ]]; then
    echo "memory slot cannot contain /" >&2
    return 1
  fi

  if [[ "$slot" == .* ]]; then
    echo "memory slot cannot start with ." >&2
    return 1
  fi

  printf '%s/memory_%s' "$PROMPT_TOOLS_DIR" "$slot"
}

_pcopy_osc52() {
  local file="$1"

  if ! command -v base64 >/dev/null 2>&1; then
    return 1
  fi

  # OSC52 is often the best option for copying from an SSH session
  # into the local terminal clipboard. It depends on terminal support.
  local encoded

  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    encoded="$(base64 -w 0 "$file")"
  else
    encoded="$(base64 "$file" | tr -d '\n')"
  fi

  if [[ -z "$encoded" ]]; then
    return 1
  fi

  printf '\033]52;c;%s\a' "$encoded"
  return 0
}

_pxml_escape_attr() {
  # Escape text for use inside an XML attribute.
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//\"/&quot;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

_pxml_cdata() {
  # Safely emit text inside CDATA.
  # Handles the rare case where file content contains "]]>".
  # Also strips Windows carriage returns.
  sed -e 's/\r$//' -e 's/]]>/]]]]><![CDATA[>/g' "$1"
}

_prelpath() {
  realpath --relative-to="$(pwd)" "$1" 2>/dev/null || printf '%s' "$1"
}

_pgit_status() {
  local file="$1"

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local status
    status="$(git status --short -- "$file" 2>/dev/null | awk '{print $1}' | head -n 1)"
    [[ -n "$status" ]] && printf '%s' "$status" || printf 'clean'
  else
    printf 'not_git_repo'
  fi
}

_pfile_lang() {
  local file="$1"

  case "$file" in
    *.R|*.r) printf 'r' ;;
    *.py) printf 'python' ;;
    *.sh|*.bash) printf 'bash' ;;
    *.sql) printf 'sql' ;;
    *.js) printf 'javascript' ;;
    *.ts) printf 'typescript' ;;
    *.html) printf 'html' ;;
    *.css) printf 'css' ;;
    *.json) printf 'json' ;;
    *.yaml|*.yml) printf 'yaml' ;;
    *.toml) printf 'toml' ;;
    *.md) printf 'markdown' ;;
    *.xml) printf 'xml' ;;
    *) printf 'text' ;;
  esac
}

_pwrap_one() {
  local file="$1"
  local out="$2"

  if [[ ! -f "$file" ]]; then
    return 1
  fi

  local relpath lines size_kb git_status lang
  relpath="$(_prelpath "$file")"
  lines="$(wc -l < "$file" | tr -d ' ')"
  size_kb="$(du -k "$file" | cut -f1)"
  git_status="$(_pgit_status "$file")"
  lang="$(_pfile_lang "$file")"

  {
    printf '<file path="%s" language="%s" lines="%s" size_kb="%s" git_status="%s">\n' \
      "$(_pxml_escape_attr "$relpath")" \
      "$(_pxml_escape_attr "$lang")" \
      "$(_pxml_escape_attr "$lines")" \
      "$(_pxml_escape_attr "$size_kb")" \
      "$(_pxml_escape_attr "$git_status")"

    printf '<![CDATA[\n'
    _pxml_cdata "$file"
    printf '\n]]>\n'
    printf '</file>\n\n'
  } >> "$out"
}

_pwrap_usage() {
  cat >&2 <<'EOF'
Usage:
  pwrap [--reset] [--note "text"] [--section NAME] [--tree] [--tree-depth N] [--from FILE] [--diff] [--diff-staged] [--diff-main] <file/dir/glob> ...

Examples:
  pwrap --reset --note "Review this change"
  pwrap --tree --tree-depth 5
  pwrap --from files.txt
  pwrap --section current --from files.txt
  pwrap --section proposed R/app_server_new.R
  pwrap --diff
  pfinish

Options:
  --reset          Clear ~/.prompt.xml before appending, backing up previous contents.
  --note TEXT      Append a <task> block.
  --section NAME   Wrap files in <section name="NAME">...</section>.
  --tree           Append a project tree.
  --tree-depth N   Set project tree depth. Default: 3.
  --from FILE      Read file/dir/glob patterns from FILE, one per line.
  --diff           Append git diff for working tree.
  --diff-staged    Append staged git diff.
  --diff-main      Append diff from merge-base with origin/main or origin/master.

Memory:
  pw [slot]         Save current prompt to memory slot. Default slot: w.
  p@ [slot]         Append memory slot back into current prompt. Default slot: w.
  pD               Delete memory files and last_truncate after confirmation.
  prestore         Append last_truncate back into current prompt.

Serve:
  pserve           Serve ~/.prompt.xml through plotsrv.
  pserve --port N  Set port. Default: 8001.
  pserve --host H  Set host. Default: 0.0.0.0.
  pserve --refresh Recreate/refresh the pserve uv environment.
  pstop            Stop pserve.
  pstop --delete   Stop pserve and delete ~/.bashrc.d/pserve.
EOF
}

_pkb() {
  _pensure
  du -k "$PROMPT_XML_FILE" | cut -f1
}

_pwrap_success() {
  local before_kb="$1"
  local after_kb
  local added_kb

  after_kb="$(_pkb)"
  added_kb=$((after_kb - before_kb))

  if [[ "$added_kb" -lt 0 ]]; then
    added_kb=0
  fi

  echo "pwrap: appended successfully. +${added_kb} KB (total: ${after_kb} KB)"
}

_pread_patterns_from_file() {
  local list_file="$1"

  if [[ ! -f "$list_file" ]]; then
    echo "pwrap: --from file not found: $list_file" >&2
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Trim leading/trailing whitespace.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    # Ignore blank lines and comments.
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    printf '%s\n' "$line"
  done < "$list_file"
}



_pwrap_tree() {
  local out="$1"
  local depth="${2:-3}"

  {
    printf '<project_tree cwd="%s" depth="%s">\n' \
      "$(_pxml_escape_attr "$(pwd)")" \
      "$(_pxml_escape_attr "$depth")"
    printf '<![CDATA[\n'

    if command -v tree >/dev/null 2>&1; then
      tree -a -L "$depth" \
        -I '.git|renv|.venv|venv|__pycache__|node_modules|.pytest_cache|.pytest_tmp_dontcare|.mypy_cache|.ruff_cache|dist|*.egg-info'
    else
      find . \
        \( -path './.git' -o -path './renv' -o -path './.venv' -o -path './venv' -o -path './__pycache__' -o -path './node_modules' -o -path './.pytest_cache' -o -path './.pytest_tmp_dontcare' -o -path './dist' \) -prune \
        -o -maxdepth "$depth" -print | sort
    fi

    printf ']]>\n'
    printf '</project_tree>\n\n'
  } >> "$out"
}

pwrap() {
  local out="$PROMPT_XML_FILE"
  local section=""
  local note=""
  local add_tree=0
  local tree_depth=3
  local add_diff=0
  local add_diff_staged=0
  local add_diff_main=0
  local from_file=""
  local any=0
  local before_kb

  if [[ $# -eq 0 ]]; then
    _pwrap_usage
    return 1
  fi

  _pensure
  before_kb="$(_pkb)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reset)
        _pbackup_then_truncate
        before_kb="$(_pkb)"
        shift
        ;;

      --note)
        if [[ -z "${2:-}" ]]; then
          echo "pwrap: --note requires text." >&2
          return 1
        fi
        note="$2"
        shift 2
        ;;

      --section)
        if [[ -z "${2:-}" ]]; then
          echo "pwrap: --section requires a name." >&2
          return 1
        fi
        section="$2"
        shift 2
        ;;

      --tree)
        add_tree=1
        shift
        ;;

      --tree-depth)
        if [[ -z "${2:-}" ]]; then
          echo "pwrap: --tree-depth requires a number." >&2
          return 1
        fi

        if ! [[ "$2" =~ ^[0-9]+$ ]]; then
          echo "pwrap: --tree-depth must be a non-negative integer." >&2
          return 1
        fi

        tree_depth="$2"
        shift 2
        ;;

      --from|--files)
        if [[ -z "${2:-}" ]]; then
          echo "pwrap: --from requires a file path." >&2
          return 1
        fi
        from_file="$2"
        shift 2
        ;;

      --diff)
        add_diff=1
        shift
        ;;

      --diff-staged)
        add_diff_staged=1
        shift
        ;;

      --diff-main)
        add_diff_main=1
        shift
        ;;

      --help|-h)
        _pwrap_usage
        return 0
        ;;

      --)
        shift
        break
        ;;

      -*)
        echo "pwrap: unknown option: $1" >&2
        _pwrap_usage
        return 1
        ;;

      *)
        break
        ;;
    esac
  done

  if [[ -n "$note" ]]; then
    {
      printf '<task>\n'
      printf '<![CDATA[\n%s\n]]>\n' "$note"
      printf '</task>\n\n'
    } >> "$out"
    any=1
  fi

  if [[ "$add_tree" -eq 1 ]]; then
    _pwrap_tree "$out" "$tree_depth"
    any=1
  fi

  if [[ "$add_diff" -eq 1 ]]; then
    _pwrap_git_diff "$out" "working"
    any=1
  fi

  if [[ "$add_diff_staged" -eq 1 ]]; then
    _pwrap_git_diff "$out" "staged"
    any=1
  fi

  if [[ "$add_diff_main" -eq 1 ]]; then
    _pwrap_git_diff "$out" "main"
    any=1
  fi

  local patterns=()

  while [[ $# -gt 0 ]]; do
    patterns+=("$1")
    shift
  done

  if [[ -n "$from_file" ]]; then
    local from_pattern
    while IFS= read -r from_pattern; do
      patterns+=("$from_pattern")
    done < <(_pread_patterns_from_file "$from_file") || return 1
  fi

  if [[ "${#patterns[@]}" -gt 0 ]]; then
    if [[ -n "$section" ]]; then
      {
        printf '<section name="%s">\n\n' "$(_pxml_escape_attr "$section")"
      } >> "$out"
    fi

    local file_any=0

    for pat in "${patterns[@]}"; do
      # Directory: one level only, matching your existing behaviour.
      if [[ -d "$pat" ]]; then
        while IFS= read -r -d '' f; do
          _pwrap_one "$f" "$out"
          file_any=1
          any=1
        done < <(find "$pat" -maxdepth 1 -type f -print0 | sort -z)
        continue
      fi

      # Glob.
      local matched=0
      while IFS= read -r f; do
        if [[ -f "$f" ]]; then
          _pwrap_one "$f" "$out"
          matched=1
          file_any=1
          any=1
        fi
      done < <(compgen -G "$pat" | sort)

      # Direct file fallback.
      if [[ "$matched" -eq 0 && -f "$pat" ]]; then
        _pwrap_one "$pat" "$out"
        file_any=1
        any=1
      fi
    done

    if [[ -n "$section" ]]; then
      {
        printf '</section>\n\n'
      } >> "$out"
    fi

    if [[ "$file_any" -eq 0 ]]; then
      echo "pwrap: no files matched." >&2
    fi
  fi

  if [[ "$any" -eq 0 ]]; then
    echo "pwrap: nothing appended." >&2
    return 1
  fi

  _pwrap_success "$before_kb"
}

_pwrap_git_diff() {
  local out="$1"
  local mode="$2"

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "pwrap: --diff requested but this is not a git repository." >&2
    return 1
  fi

  {
    printf '<git_diff mode="%s">\n' "$(_pxml_escape_attr "$mode")"
    printf '<![CDATA[\n'

    case "$mode" in
      working)
        git diff --no-ext-diff
        ;;

      staged)
        git diff --cached --no-ext-diff
        ;;

      main)
        local base_ref=""
        if git rev-parse --verify origin/main >/dev/null 2>&1; then
          base_ref="origin/main"
        elif git rev-parse --verify main >/dev/null 2>&1; then
          base_ref="main"
        elif git rev-parse --verify origin/master >/dev/null 2>&1; then
          base_ref="origin/master"
        elif git rev-parse --verify master >/dev/null 2>&1; then
          base_ref="master"
        fi

        if [[ -z "$base_ref" ]]; then
          echo "pwrap: could not find main/master branch for --diff-main." >&2
        else
          local merge_base
          merge_base="$(git merge-base HEAD "$base_ref")"
          git diff --no-ext-diff "$merge_base"..HEAD
        fi
        ;;
    esac

    printf ']]>\n'
    printf '</git_diff>\n\n'
  } >> "$out"
}

pfinish() {
  local out="$PROMPT_XML_FILE"
  _pensure

  {
    printf '<prompt_summary>\n'
    printf '  <generated_at>%s</generated_at>\n' "$(_pxml_escape_attr "$(date '+%Y-%m-%d %H:%M:%S %z')")"
    printf '  <cwd>%s</cwd>\n' "$(_pxml_escape_attr "$(pwd)")"
    printf '  <prompt_file>%s</prompt_file>\n' "$(_pxml_escape_attr "$out")"
    printf '  <prompt_size_kb>%s</prompt_size_kb>\n' "$(_pxml_escape_attr "$(du -k "$out" | cut -f1)")"
    printf '  <git_branch>%s</git_branch>\n' "$(_pxml_escape_attr "$(_pcurrent_branch)")"
    printf '  <manifest>\n'

    _pmanifest_from_prompt "$out"

    printf '  </manifest>\n'
    printf '</prompt_summary>\n\n'
  } >> "$out"
}

_pcurrent_branch() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git branch --show-current 2>/dev/null || printf 'unknown'
  else
    printf 'not_git_repo'
  fi
}

_pmanifest_from_prompt() {
  local out="$1"

  # Extract paths from existing <file ...> blocks.
  # This intentionally includes repeated files if you appended the same file more than once.
  grep -o '<file path="[^"]*".*>' "$out" 2>/dev/null |
    sed -E 's/.*path="([^"]*)".*language="([^"]*)".*lines="([^"]*)".*size_kb="([^"]*)".*git_status="([^"]*)".*/    <file path="\1" language="\2" lines="\3" size_kb="\4" git_status="\5"\/>/'
}

pserve() {
  local host="0.0.0.0"
  local port="8001"
  local refresh=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host)
        if [[ -z "${2:-}" ]]; then
          echo "pserve: --host requires a value." >&2
          return 1
        fi
        host="$2"
        shift 2
        ;;

      --port)
        if [[ -z "${2:-}" ]]; then
          echo "pserve: --port requires a value." >&2
          return 1
        fi
        port="$2"
        shift 2
        ;;

      --refresh)
        refresh=1
        shift
        ;;

      --help|-h)
        cat >&2 <<'EOF'
Usage:
  pserve [--host HOST] [--port PORT] [--refresh]

Examples:
  pserve
  pserve --port 8001
  pserve --host 0.0.0.0 --port 8001
  pserve --refresh
EOF
        return 0
        ;;

      *)
        echo "pserve: unknown option: $1" >&2
        return 1
        ;;
    esac
  done

  _pensure

  if ! command -v uv >/dev/null 2>&1; then
    echo "pserve: uv is not installed or not on PATH." >&2
    echo "Install uv first, then try again." >&2
    return 1
  fi

  mkdir -p "$PSERVE_DIR"

  if [[ -f "$PSERVE_PID_FILE" ]]; then
    local old_pid
    old_pid="$(cat "$PSERVE_PID_FILE" 2>/dev/null)"

    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" >/dev/null 2>&1; then
      if [[ "$refresh" -eq 1 ]]; then
        echo "pserve: existing instance is running; stopping it before refresh."
        pstop
      else
        echo "pserve: already running with PID $old_pid"
        echo "pserve: log: $PSERVE_LOG_FILE"
        return 0
      fi
    fi
  fi

  (
    cd "$PSERVE_DIR" || exit 1

    if [[ "$refresh" -eq 1 ]]; then
      rm -rf .venv uv.lock
    fi

    if [[ ! -f pyproject.toml ]]; then
      uv init
    fi

    if [[ ! -d .venv ]]; then
      uv venv
    fi

    if [[ "$refresh" -eq 1 ]]; then
      uv add plotsrv
    elif ! grep -q 'plotsrv' pyproject.toml 2>/dev/null; then
      uv add plotsrv
    fi
  ) || {
    echo "pserve: failed to initialise uv project in $PSERVE_DIR" >&2
    return 1
  }

  : > "$PSERVE_LOG_FILE"

  (
    cd "$PSERVE_DIR" || exit 1

    nohup uv run plotsrv run "$PSERVE_DIR" \
      --host "$host" \
      --port "$port" \
      --watch "$PROMPT_XML_FILE" \
      --no-truncate \
      > "$PSERVE_LOG_FILE" 2>&1 &

    echo $! > "$PSERVE_PID_FILE"
  )

  local pid
  pid="$(cat "$PSERVE_PID_FILE" 2>/dev/null)"

  echo "pserve: started plotsrv with PID $pid"
  echo "pserve: serving $PROMPT_XML_FILE"
  echo "pserve: http://$host:$port"
  echo "pserve: log: $PSERVE_LOG_FILE"
}

pstop() {
  local delete_dir=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delete)
        delete_dir=1
        shift
        ;;

      --help|-h)
        cat >&2 <<'EOF'
Usage:
  pstop [--delete]

Options:
  --delete   Stop pserve and delete ~/.bashrc.d/pserve.
EOF
        return 0
        ;;

      *)
        echo "pstop: unknown option: $1" >&2
        return 1
        ;;
    esac
  done

  if [[ -f "$PSERVE_PID_FILE" ]]; then
    local pid
    pid="$(cat "$PSERVE_PID_FILE" 2>/dev/null)"

    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid"
      echo "pstop: stopped PID $pid"
    else
      echo "pstop: no running process found for PID file."
    fi

    rm -f "$PSERVE_PID_FILE"
  else
    echo "pstop: no PID file found."
  fi

  if [[ "$delete_dir" -eq 1 ]]; then
    rm -rf "$PSERVE_DIR"
    echo "pstop: deleted $PSERVE_DIR"
  fi
}

