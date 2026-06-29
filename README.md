# Homebrew dev container

A portable Linux development environment in a container, with everything installed via **Homebrew** so your host machine stays clean. Mount any project folder, work inside it with a full toolchain, and `brew install` anything new whenever you want. Shell is **zsh + oh-my-zsh**.

The headline feature: a single `code <folder>` command that opens **VSCode running *inside* a per-folder container** — so every project gets its own isolated environment automatically, and you never install language tools on your laptop again.

**Pre-installed:** `git`, `helm`, `kubectl`, `az` (Azure CLI), `node` + `nvm`, `python` (latest) + `pip`, `uv`, `claude` (Claude Code), and `zsh` with oh-my-zsh. Add anything else with `brew install`.

---

## Table of contents

- [Prerequisites](#prerequisites)
- [Option A — VSCode, one container per folder (recommended)](#option-a--vscode-one-container-per-folder-recommended)
- [Option B — Docker Compose](#option-b--docker-compose)
- [Option C — Plain docker](#option-c--plain-docker)
- [How the `code` launcher works](#how-the-code-launcher-works)
- [Claude Code inside the container](#claude-code-inside-the-container)
- [Customizing zsh](#customizing-zsh)
- [Installing new tools at runtime](#installing-new-tools-at-runtime)
- [Tool notes](#tool-notes)
- [Security notes](#security-notes)
- [Apple Silicon](#apple-silicon)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

- **Docker Desktop** (macOS / Windows) or Docker Engine (Linux).
- For Option A: **VSCode** with the `code` shell command on your PATH
  (in VSCode: `Cmd/Ctrl+Shift+P → Shell Command: Install 'code' command in PATH`)
  and the **Dev Containers** extension:
  ```bash
  code --install-extension ms-vscode-remote.remote-containers
  ```
- A POSIX shell. The `code` launcher (Option A) is written for **zsh** (macOS default).

Clone this repo anywhere you like — every path below is relative or uses `$HOME`, so nothing is hardcoded:

```bash
git clone <this-repo-url> "$HOME/dev-container"   # or wherever you prefer
cd "$HOME/dev-container"
```

---

## Option A — VSCode, one container per folder (recommended)

Run `code <folder>` and VSCode opens **attached to a container** for that folder: the integrated terminal, extensions, and tools all run *inside* the container, with your folder mounted at `/workspace`. Open a different folder and you get a **separate** container — work on many projects at once, fully isolated.

### One-time setup

**1. Build the image** (reused by every project; uses your own UID/GID so mounted files stay owned by you):

```bash
USER_UID=$(id -u) USER_GID=$(id -g) docker compose build
```

**2. Load the `code` launcher** — add this to your host `~/.zshrc`, then remove any existing `alias code=...` line:

```sh
source "$HOME/dev-container/host-code.zsh"   # adjust to where you cloned this repo
```

Reload your shell (`source ~/.zshrc` or open a new terminal). Verify:

```sh
which code      # should print "code () { ... }", not an alias
```

**3. Auto-install Claude Code in every container** — add to your VSCode **user** `settings.json`
(`Cmd/Ctrl+Shift+P → Preferences: Open User Settings (JSON)`):

```jsonc
"dev.containers.defaultExtensions": ["anthropic.claude-code"]
```

### Daily use

```sh
code                  # open the current folder in its dev container
code ~/work/api       # open that folder in its own container
code ~/personal/api   # a SEPARATE container, even though both are named "api"
code notes.txt        # a file (not a folder) → falls through to plain VSCode
```

Helper commands (also from `host-code.zsh`):

| Command            | What it does                                                        |
| ------------------ | ------------------------------------------------------------------- |
| `devls`            | List your dev containers and their status                           |
| `devstop [folder]` | Stop a folder's container (frees RAM, **keeps** all state)          |
| `devrm   [folder]` | Remove a folder's container (keeps the named volumes / your logins) |

> **Note:** in this attach-based mode, closing the VSCode window does **not** stop the
> container — run `devstop` when you're done with a project. Reopening with `code` reuses
> the stopped container, so your files and any runtime `brew install`s are still there.

---

## Option B — Docker Compose

No VSCode required — a single long-lived container mounting the current folder.

```bash
# 1. Build (your UID/GID keep mounted files owned by you)
USER_UID=$(id -u) USER_GID=$(id -g) docker compose build

# 2. Start it in the background
docker compose up -d

# 3. Drop into a zsh shell
docker compose exec dev zsh
```

You land in `/workspace` (the folder mounted in `docker-compose.yml`) as the `dev` user with passwordless `sudo`. Stop with `docker compose down` (named config volumes persist). Rebuild after editing the `Dockerfile` with `docker compose build && docker compose up -d`.

---

## Option C — Plain docker

```bash
docker build -t brew-dev \
  --build-arg USER_UID=$(id -u) \
  --build-arg USER_GID=$(id -g) .

docker run -it --rm \
  -v "$PWD":/workspace \
  -v "$PWD/zshrc":/home/dev/.zshrc \
  -v brew-claude:/home/dev/.claude \
  brew-dev
```

---

## How the `code` launcher works

[`host-code.zsh`](host-code.zsh) defines a `code` shell function that, when you pass it a folder:

1. **Builds the shared image once** (`brew-dev:latest`) if it doesn't exist yet — every project reuses it.
2. **Names the container `dev-<folder>-<pathhash>`**, where the hash is derived from the folder's *full* path. This is why `~/work/api` and `~/personal/api` get distinct containers instead of colliding.
3. **Starts the container** (or reuses an existing one) with your folder bind-mounted at `/workspace` and per-project named volumes for `~/.claude`, `~/.azure`, `~/.kube`.
4. **Attaches VSCode** into the running container via a `vscode-remote://attached-container+…` URI.

The launcher auto-detects its own location (`DEVCONTAINER_REPO`), so it works wherever you cloned the repo. Override the defaults by exporting them before sourcing:

```sh
export DEVCONTAINER_REPO="$HOME/some/other/path"
export DEVCONTAINER_IMAGE="brew-dev:latest"
```

### Container lifecycle & what persists

| Event                        | What happens                                                          |
| ---------------------------- | -------------------------------------------------------------------- |
| Close the VSCode window      | Container keeps running (use `devstop` to stop it)                   |
| `devstop` then reopen        | Same container is **started again** — files + runtime installs intact |
| `devrm` / "Rebuild Container" | Container thrown away; only the mounted folder + named volumes survive |

Anything you want to keep permanently goes in `/workspace` (lives on your host) or a named volume — not loose in the container filesystem.

---

## Claude Code inside the container

When VSCode is attached to a container, the **Claude Code extension runs inside the container**, using the container's `claude` binary, filesystem, PATH, and tools. Practical implications:

- The `claude` CLI is already installed (Anthropic's native installer; the npm method is deprecated as of early 2026). Run `claude` to start; first launch handles auth. `claude doctor` checks the install.
- **Auth is per-container** and persisted in a named volume, so you log in once per project and it survives stop/start (lost only on `devrm`/rebuild). To share one login across all projects instead, point the `claude-*` volume at a single shared volume name in `host-code.zsh`.
- The `dev.containers.defaultExtensions` setting (see Option A) auto-installs the extension into every container, including the plain Compose/attach ones.

---

## Customizing zsh

> **Two different `.zshrc` files — don't confuse them:**
> - [`zshrc`](zshrc) in **this repo** is the **container's** shell config. It's mounted to `/home/dev/.zshrc` *inside* the container and only affects shells running there.
> - Your **host** `~/.zshrc` is your laptop's own config — that's where the `source .../host-code.zsh` line for the `code` launcher goes ([Option A](#option-a--vscode-one-container-per-folder-recommended)).
>
> Editing one never touches the other.

Your container `.zshrc` lives as [`zshrc`](zshrc) in this repo and is mounted into the Compose container. **Edit it on your host** with any editor — changes persist and survive rebuilds. In a running shell, run `source ~/.zshrc` or open a new one to pick them up.

- Change the theme: edit `ZSH_THEME="robbyrussell"` (try `agnoster`, `bira`, …).
- Add plugins: e.g. `plugins=(git kubectl helm npm docker)`.
- Add aliases at the bottom.
- Keep the `source "$HOME/.dev-shell-env.sh"` line — that's what keeps `brew`, `node`, and `python` on your PATH.

---

## Installing new tools at runtime

```bash
brew install <whatever>      # e.g. brew install jq terraform k9s
sudo apt-get install <pkg>   # apt also works if you prefer
```

Persistence:

- **Permanent / reproducible** → add the package to the `brew install ...` line in the [`Dockerfile`](Dockerfile) and rebuild. Recommended — keeps your toolchain in version control.
- **Just for now** → `brew install` in the running container. Survives stop/start, lost on removal. Fine for experiments.

---

## Tool notes

- **node / nvm** — Node comes from `nvm` (latest current, set as default). Switch with `nvm install --lts`, `nvm use 20`, etc.
- **python / pip** — Homebrew's Python is "externally managed" (PEP 668), so a bare `pip install requests` refuses to touch the global env. Use a virtualenv:
  ```bash
  uv venv && source .venv/bin/activate   # fast, recommended
  # or: python -m venv .venv && source .venv/bin/activate
  pip install requests
  ```
  (To force a global install: `pip install --break-system-packages <pkg>`.)
- **az / kubectl** — `az login` and kube contexts persist via their named volumes.

---

## Security notes

This setup keeps your host OS clean and, on Docker Desktop (macOS/Windows), runs inside a lightweight VM that adds a real isolation layer. Good for everyday development with code/packages you broadly trust. Sensible habits:

- **Mount only the folder you're working in** — anything in the container can read/write mounted host paths. Don't mount your whole home dir or `~/.ssh`.
- `no-new-privileges` is already set (in `docker-compose.yml` and via the launcher's `docker run`), blocking privilege-escalation tricks.
- Don't bake secrets (API keys, passwords) into the Dockerfile or drop them into broadly-mounted folders.
- If you don't use `sudo apt-get` inside the container, you can remove the passwordless-sudo lines from the Dockerfile to tighten things further.
- For genuinely *untrusted* code, use a fresh throwaway container you delete afterward.

---

## Apple Silicon

Works as-is. Runs as `linux/arm64`; Homebrew supports ARM Linux. No changes needed.

---

## Troubleshooting

**`apt-get update` fails with `Could not connect to ports.ubuntu.com:80 … connection timed out`**

Some networks (corporate firewalls, VPNs, certain ISPs) silently drop **port 80** to the Ubuntu mirrors, which sit behind Cloudflare. The build then can't fetch package indexes and errors with `Unable to locate package …`. This repo's [`Dockerfile`](Dockerfile) already works around it by fetching the apt indexes over **HTTPS**:

```dockerfile
RUN sed -i 's|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get -o Acquire::https::Verify-Peer=false update \
    && apt-get -o Acquire::https::Verify-Peer=false install -y --no-install-recommends ...
```

TLS peer verification is disabled **only for this first apt run** (the bare image has no CA certs yet); apt still GPG-verifies the signed package indexes, so integrity is guaranteed. Once `ca-certificates` is installed, every later HTTPS call verifies normally.

**`defining function based on alias 'code'` when sourcing `host-code.zsh`**

You still have an `alias code=...` defined. The script runs `unalias code` before defining the function, but if your alias line in `~/.zshrc` comes *after* the `source` line it re-shadows the function. Remove the old `alias code=...` line.

**`which code` shows a path, not a function**

The launcher wasn't sourced (or got shadowed). Confirm the `source "$HOME/.../host-code.zsh"` line is in `~/.zshrc`, after any code that might redefine `code`, then reload your shell.
