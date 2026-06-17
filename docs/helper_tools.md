# helper_scripts tools

Personal reference for tools installed from `helper_scripts`.

This repo is public, but these notes are for my own machines/workflows.

---

# Bootstrap

Clone:

```bash
git clone git@github.com:anees-hill/helper_scripts.git
cd helper_scripts
```

Basic setup:

```bash
sudo bash bootstrap.sh --simple --user samane
```

IDE-ish setup:

```bash
sudo bash bootstrap.sh --ide --user samane
```

Install individual components:

```bash
sudo bash bootstrap.sh --core --user samane
sudo bash bootstrap.sh --bashrc --user samane
sudo bash bootstrap.sh --pwrap --user samane
sudo bash bootstrap.sh --psync --user samane
sudo bash bootstrap.sh --tmux --user samane
sudo bash bootstrap.sh --nvim --user samane
sudo bash bootstrap.sh --visidata --user samane
sudo bash bootstrap.sh --tools --user samane
```

`psync` is installed explicitly. It is not part of `--ide`.

---

# Core helper_scripts commands

Installed with:

```bash
sudo bash bootstrap.sh --core --user samane
```

## pver

Show helper_scripts version, repo path, git commit, and registered components:

```bash
pver
```

JSON output:

```bash
pver --json
```

## pregister

Register which helper_scripts components are installed on this machine:

```bash
pregister --core --bashrc --pwrap --psync --tmux
```

Manifest:

```text
~/.config/helper_scripts/install.json
```

## pupdate

Show what would update:

```bash
pupdate --dry-run
```

Pull latest repo and reinstall registered components:

```bash
pupdate
```

Reinstall registered components from current checkout without `git pull`:

```bash
pupdate --no-pull
```

---

# Bash helpers

Installed with:

```bash
sudo bash bootstrap.sh --bashrc --user samane
```

Managed file:

```text
~/.bashrc.d/helper_settings.sh
```

Local private customisations:

```text
~/.bashrc.d/bash_local.sh
```

Useful aliases/functions include:

```bash
e        # nvim
gs       # git status
gl       # git graph log
ve       # source .venv/bin/activate
ports    # sudo lsof -i -P -n
topcpu
topmem
topmix
topcpuavg
topmemavg
```

---

# pwrap

Installed with:

```bash
sudo bash bootstrap.sh --pwrap --user samane
```

Prompt file:

```text
~/.prompt.xml
```

Common flow:

```bash
pwrap --reset --note "Review this change"
pwrap --tree --tree-depth 4
pwrap files/bin/psync bootstrap.sh
pwrap --diff
pfinish
pcopy
```

Useful commands:

```bash
ptrunc       # clear prompt file, backing up previous contents
prestore     # restore last truncated prompt content
psize        # prompt size in KB
popen        # open ~/.prompt.xml in nvim
pcat         # cat ~/.prompt.xml
phead        # head ~/.prompt.xml
ptail        # tail ~/.prompt.xml
pcopy        # copy prompt to clipboard
pfinish      # append prompt summary/manifest
```

Memory slots:

```bash
pw           # save current prompt to default memory slot
p@           # append default memory slot back into prompt
pw a         # save to slot a
p@ a         # recall slot a
pD           # delete prompt memory files after confirmation
```

Serve prompt file via plotsrv:

```bash
pserve
pserve --port 8001
pstop
```

---

# psync

Installed with:

```bash
sudo bash bootstrap.sh --psync --user samane
```

`psync` is `rsync` plus remembered scheduled jobs.

Normal idea:

```bash
psync -azv source destination
```

This:

1. runs `rsync` immediately
2. saves the job if the run succeeds
3. does not create a duplicate if the same job already exists
4. can run later via systemd user timer

If a new command fails, no job is created.

---

## Workflow 1: local sync

Use this when both source and destination are local paths.

```bash
mkdir -p ~/backups/project
cd ~/backups/project

psync -azv ~/Documents/project/ .
```

Start scheduler:

```bash
psync_start
```

Check:

```bash
psync_status
psync_status --schedule
```

---

## Workflow 2: remote sync using existing SSH access

Use this when normal SSH already works.

Test:

```bash
ssh samane@myserver
```

If that logs in without needing a password, then `psync` can use the same route:

```bash
mkdir -p ~/backups/server-data
cd ~/backups/server-data

psync -azv samane@myserver:/home/samane/data/ .
```

If SSH asks for a password, scheduled `psync` is not ready yet. Set up key-based SSH first, or use `psync_host`.

---

## Workflow 3: remote sync using existing SSH key, but psync-managed alias

Use this when I already have a key, but do not want to edit `~/.ssh/config`.

```bash
psync_host add pd \
  --host pd.internal \
  --user samane \
  --identity-file ~/.ssh/id_ed25519
```

Test:

```bash
psync_host test pd
```

Use:

```bash
mkdir -p ~/backups/pd-data
cd ~/backups/pd-data

psync -azv pd:/home/samane/data/ .
```

psync stores its own SSH config in:

```text
~/.config/psync/ssh/config
```

It does not edit:

```text
~/.ssh/config
```

---

## Workflow 4: create a psync SSH key

Use this when two machines can SSH with a password now, but scheduled non-interactive syncs need key-based access.

On the machine that will run `psync`:

```bash
psync_host add pd --host pd.internal --user samane
```

This creates:

```text
~/.config/psync/ssh/keys/pd
~/.config/psync/ssh/keys/pd.pub
```

Install the public key on the remote:

```bash
psync_host install-key pd
```

This may ask for the remote password once.

Test:

```bash
psync_host test pd
```

Then use:

```bash
mkdir -p ~/backups/pd-data
cd ~/backups/pd-data

psync -azv pd:/home/samane/data/ .
```

---

## Workflow 5: server-to-server sync

Example: `pp` pulls from `pd`.

Run this on `pp`:

```bash
psync_host add pd --host pd.internal --user samane
psync_host install-key pd
psync_host test pd
```

Then on `pp`:

```bash
mkdir -p /backups/pd
cd /backups/pd

psync -azv pd:/home/samane/data/ .
psync_start
```

Mental model:

```text
psync runs on pp
pp needs access to pd
pp owns the private key
pd trusts pp's public key
```

For `pd` pulling from `pp`, do the same thing in reverse on `pd`.

---

## Workflow 6: versioned backups

Use this when I want timestamped backup folders rather than one overwritten destination.

Keep last 3 versions:

```bash
mkdir -p ~/backups/pd-data
cd ~/backups

psync --versions 3 -- -azv pd:/home/samane/data/ ./pd-data/
```

Creates folders like:

```text
pd-data/
├── 2026-06-17_110000/
├── 2026-06-18_110000/
└── 2026-06-19_110000/
```

Old versions are removed after successful runs.

By default, versioned backups use hard links via `rsync --link-dest`, so unchanged files are not duplicated.

Disable hard links:

```bash
psync --versions 3 --no-link-dest -- -azv pd:/home/samane/data/ ./pd-data/
```

Versioned destination must be local:

```bash
psync --versions 3 -- -azv pd:/data/ ./backups/
```

Do not use remote destination versioning yet:

```bash
psync --versions 3 -- -azv ./data/ pd:/backups/
```

---

## Workflow 7: daily versioned backup at 11:00

```bash
mkdir -p ~/backups/pd-data
cd ~/backups

psync --versions 3 -- -azv pd:/home/samane/data/ ./pd-data/
psync_adjust --entry 1 --every 24h --at 11:00
psync_start
```

This means:

```text
Run daily at 11:00
Keep last 3 versions
Use hard links for unchanged files
```

---

## psync scheduling

Start scheduler:

```bash
psync_start
```

Stop scheduler:

```bash
psync_stop
```

Check status:

```bash
psync_status
```

Upcoming runs:

```bash
psync_status --schedule
```

More upcoming runs:

```bash
psync_status --schedule --next 20
```

One job only:

```bash
psync_status --schedule --entry 1
```

---

## Adjust psync jobs

Change interval:

```bash
psync_adjust --entry 1 --every 30m
```

Daily at a fixed time:

```bash
psync_adjust --entry 1 --every 24h --at 11:00
```

Clear fixed time:

```bash
psync_adjust --entry 1 --clear-at
```

Disable job:

```bash
psync_adjust --entry 1 --off
```

Enable job:

```bash
psync_adjust --entry 1 --on
```

Supported intervals:

```text
30s
5m
2h
24h
1d
```

`--at` is for schedules of 24h / 1d or longer.

---

## Run psync jobs now

Run all enabled jobs:

```bash
psync_now
```

Run one job:

```bash
psync_now --entry 1
```

---

## psync logs

Recent runs:

```bash
psync_log
```

One job:

```bash
psync_log --entry 1
```

Only errors:

```bash
psync_log --errors
```

Verbose:

```bash
psync_log --entry 1 --verbose
```

More rows:

```bash
psync_log --lines 50
```

---

## Remove psync job

```bash
psync_remove --entry 1
```

This removes the stored job. It does not delete synced files.

---

## psync_host reference

List hosts:

```bash
psync_host list
```

Show host:

```bash
psync_host show pd
```

Show public key:

```bash
psync_host show-key pd
```

Add generated-key host:

```bash
psync_host add pd --host pd.internal --user samane
```

Add host with existing key:

```bash
psync_host add pd \
  --host pd.internal \
  --user samane \
  --identity-file ~/.ssh/id_ed25519
```

Install public key on remote:

```bash
psync_host install-key pd
```

Test host:

```bash
psync_host test pd
```

Remove host:

```bash
psync_host remove pd
```

Remove host and generated key:

```bash
psync_host remove pd --delete-key
```

Removing a host does not remove its public key from the remote `authorized_keys`.

---

## psync file locations

Jobs:

```text
~/.config/psync/jobs.json
```

Hosts:

```text
~/.config/psync/hosts.json
~/.config/psync/ssh/config
~/.config/psync/ssh/keys/
```

Run history:

```text
~/.local/state/psync/runs.sqlite
```

Systemd user timer:

```text
~/.config/systemd/user/psync.service
~/.config/systemd/user/psync.timer
```

---

## SQLite note

Do not sync a live SQLite database while it is being written to.

Better:

```bash
sqlite3 monitor.sqlite ".backup monitor_backup.sqlite"
psync -azv monitor_backup.sqlite pd:/backups/monitor/
```

Versioned:

```bash
sqlite3 monitor.sqlite ".backup monitor_backup.sqlite"
psync --versions 7 -- -azv monitor_backup.sqlite ./monitor-db-backups/
```

---

# tmux

Installed with:

```bash
sudo bash bootstrap.sh --tmux --user samane
```

Config installed to:

```text
~/.tmux.conf
```

Prefix:

```text
Ctrl-x
```

Reload config inside tmux:

```text
Ctrl-x r
```

---

# nvim

Installed with:

```bash
sudo bash bootstrap.sh --nvim --user samane
```

Installs Neovim AppImage to:

```text
/usr/local/bin/nvim
```

Config installed to:

```text
~/.config/nvim/init.vim
```

Main notes:

```text
leader = space
<leader>e     file tree
<leader>ff    find files
<leader>fg    live grep
<leader>rr    toggle REPL
<leader>sc    send visual/code motion to REPL
<leader>tl    toggle safe light mode
```

---

# uv

Installed with:

```bash
sudo bash bootstrap.sh --uv --user samane
```

Used for Python tooling and uv-managed CLI tools.

Common commands:

```bash
uv --version
uv venv
uv pip install -r requirements.txt
uv tool list
uv tool install PACKAGE
```

---

# Python/dev tools

Installed with:

```bash
sudo bash bootstrap.sh --tools --user samane
```

Installs via `uv tool`:

```text
pyright
black
ruff
debugpy
```

Main use:

```bash
pyright
ruff check .
black .
```

---

# VisiData

Installed with:

```bash
sudo bash bootstrap.sh --visidata --user samane
```

Installs VisiData with PostgreSQL support.

Use Postgres alias via `vdb`:

```bash
vdb OPERA_PROD trf
```

Aliases live in:

```text
~/.bashrc.d/vdb_connections
```

Example:

```bash
OPERA_PROD='postgres://user:password@host:5432/database'
```

This file is private and should not be committed.

---

# Git / line endings

For this repo, keep shell/Python/bin files as LF.

Recommended `.gitattributes`:

```text
*.sh text eol=lf
files/bin/* text eol=lf
*.py text eol=lf
*.vim text eol=lf
*.conf text eol=lf
VERSION text eol=lf
```

If needed:

```bash
sed -i 's/\r$//' bootstrap.sh
sed -i 's/\r$//' files/bin/psync
sed -i 's/\r$//' files/bin/pver
```

---

# Typical machine setup patterns

## Minimal server

```bash
sudo bash bootstrap.sh --simple --user samane
sudo bash bootstrap.sh --pwrap --tmux --user samane
```

## Machine with psync

```bash
sudo bash bootstrap.sh --simple --user samane
sudo bash bootstrap.sh --psync --user samane
pregister --core --bashrc --pwrap --psync --tmux
```

## Main dev machine

```bash
sudo bash bootstrap.sh --ide --user samane
sudo bash bootstrap.sh --psync --user samane
pregister --core --bashrc --pwrap --psync --tmux --nvim --tools --visidata
```

Update later:

```bash
pupdate --dry-run
pupdate
```

