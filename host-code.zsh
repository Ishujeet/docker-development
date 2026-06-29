# ─── Dynamic dev-container launcher for VSCode (host / macOS) ────────────────
#
# Source this from your *host* ~/.zshrc:
#     source ~/myprojects/docker-development/host-code.zsh
#
# Then:
#     code                 open the current folder in its dev container
#     code ~/work/api      open that folder in its own dev container
#     code file.txt        (a file/flag) → behaves like plain VSCode
#     devls                list running/stopped dev containers
#     devstop [folder]     stop a folder's container (frees RAM, keeps state)
#     devrm   [folder]     stop + remove a folder's container (keeps volumes)
#
# Each folder gets its OWN container, named  dev-<folder>-<pathhash>, so two
# same-named folders (e.g. ~/work/api and ~/personal/api) never collide.
# Containers are NOT auto-stopped when you close the window — use devstop.
#
# IMPORTANT: remove any existing `alias code=...` from your ~/.zshrc — this
# function replaces it (and still passes files/flags through to plain VSCode).
# ─────────────────────────────────────────────────────────────────────────────

# Drop any pre-existing `code` alias so we can define the function below.
# (zsh refuses to define a function whose name is an active alias.)
unalias code 2>/dev/null

# Where the dev-container image is defined (Dockerfile + compose live here).
# Auto-detected as the directory this file lives in, so it works no matter
# where you cloned the repo. Override by exporting DEVCONTAINER_REPO yourself.
export DEVCONTAINER_REPO="${DEVCONTAINER_REPO:-${${(%):-%x}:A:h}}"
export DEVCONTAINER_IMAGE="${DEVCONTAINER_IMAGE:-brew-dev:latest}"

# Resolve the real VSCode `code` binary, ignoring this function and any alias.
_dev_vscode_bin() {
  local bin
  bin="$(whence -p code 2>/dev/null)"
  [ -n "$bin" ] && { print -r -- "$bin"; return; }
  for c in /usr/local/bin/code /opt/homebrew/bin/code \
           "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"; do
    [ -x "$c" ] && { print -r -- "$c"; return; }
  done
  print -r -- code
}

# Map an absolute folder path → a stable, docker-safe container name.
_dev_cname() {
  local target="$1"
  local base hash
  base="$(basename "$target" | tr -c 'a-zA-Z0-9_.-' '-')"
  hash="$(printf '%s' "$target" | shasum | cut -c1-6)"
  print -r -- "dev-${base}-${hash}"
}

code() {
  local vscode_bin; vscode_bin="$(_dev_vscode_bin)"

  # No args → current dir. A non-directory arg (file/flag) → plain VSCode.
  if [ $# -eq 0 ]; then
    set -- "$PWD"
  elif [ ! -d "$1" ]; then
    "$vscode_bin" "$@"; return
  fi

  local target; target="$(cd "$1" 2>/dev/null && pwd)" \
    || { print -u2 "code: no such folder: $1"; return 1; }
  local cname; cname="$(_dev_cname "$target")"

  # 1. Build the shared image once (every project reuses it).
  if ! docker image inspect "$DEVCONTAINER_IMAGE" >/dev/null 2>&1; then
    print "code: building $DEVCONTAINER_IMAGE (first run, a few minutes)…"
    docker compose -f "$DEVCONTAINER_REPO/docker-compose.yml" build || return 1
  fi

  # 2. Ensure THIS folder's container is running (reuse if it already exists).
  if docker container inspect "$cname" >/dev/null 2>&1; then
    if [ "$(docker container inspect -f '{{.State.Running}}' "$cname")" != "true" ]; then
      print "code: starting existing container $cname"
      docker start "$cname" >/dev/null || return 1
    fi
  else
    print "code: creating container $cname  ($target → /workspace)"
    docker run -d \
      --name "$cname" \
      --hostname "$(basename "$target")" \
      --security-opt no-new-privileges \
      -w /workspace \
      -v "$target:/workspace" \
      -v "claude-${cname}:/home/dev/.claude" \
      -v "azure-${cname}:/home/dev/.azure" \
      -v "kube-${cname}:/home/dev/.kube" \
      "$DEVCONTAINER_IMAGE" sleep infinity >/dev/null || return 1
  fi

  # 3. Attach VSCode INTO the running container at /workspace.
  #    The authority is hex( {"containerName":"/<name>"} ) — how the Dev
  #    Containers extension addresses an attached container.
  local hex
  hex="$(printf '{"containerName":"/%s"}' "$cname" | xxd -p | tr -d '\n')"
  "$vscode_bin" --folder-uri "vscode-remote://attached-container+${hex}/workspace"
}

# List dev containers created by this launcher.
devls() {
  docker ps -a --filter "name=^/dev-" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
}

# Stop a folder's container (keeps it + its volumes for next time).
devstop() {
  local target; target="$(cd "${1:-$PWD}" 2>/dev/null && pwd)" || return 1
  docker stop "$(_dev_cname "$target")"
}

# Remove a folder's container (keeps the named volumes / your auth).
devrm() {
  local target; target="$(cd "${1:-$PWD}" 2>/dev/null && pwd)" || return 1
  local cname; cname="$(_dev_cname "$target")"
  docker rm -f "$cname"
}
