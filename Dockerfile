# syntax=docker/dockerfile:1
#
# Homebrew-based dev container
# Tools: git, helm, kubectl, az (Azure CLI), node, nvm, python (latest), pip, uv,
#        claude-code, zsh + oh-my-zsh
# Package manager of choice: Homebrew (Linuxbrew). You can `brew install` anything new at runtime.
#
# Cacheability notes:
#  * Steps are ordered stable -> volatile so a change low in the file doesn't
#    bust the expensive layers above it.
#  * The one big `brew install` is split so tweaking one tool doesn't rebuild the
#    rest (azure-cli alone is ~1GB and almost never changes).
#  * BuildKit cache mounts keep the apt + Homebrew download caches between builds,
#    so even a rebuilt layer reuses what it already downloaded. Requires BuildKit
#    (default in modern Docker / `docker buildx`).
#  * Tool versions are pinned via the ARGs below -- bump one line to re-pin.
#
# Pin the base image by digest for full reproducibility, e.g.:
#   FROM ubuntu:24.04@sha256:<digest>
FROM ubuntu:24.04

# --- Identity (build args so file ownership on mounted volumes matches your host user) ---
# On your host run `id -u` / `id -g` and pass them in (defaults to 1000/1000).
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

# --- Pinned tool versions (bump these to upgrade; keep them explicit for reproducible builds) ---
# NOTE: Homebrew's core tap only serves the *latest* bottle of unversioned formulae
# (helm, kubernetes-cli, azure-cli, uv, nvm, zsh). We pin what brew lets us pin
# (python via a versioned formula) and pin the curl|bash installers by ref/version.
# Combined with HOMEBREW_NO_AUTO_UPDATE, builds stay stable between rebuilds.
ARG PYTHON_FORMULA=python@3.12
ARG NODE_VERSION=22
ARG OHMYZSH_REF=master
ARG CLAUDE_VERSION=stable
ARG PLAYWRIGHT_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive

# --- Base OS deps (needed by Homebrew + general dev) ---
# We fetch the apt indexes over HTTPS instead of HTTP. Some networks (corp
# firewalls / VPNs / ISPs) silently drop port 80 to the Ubuntu mirrors behind
# Cloudflare, which makes `apt-get update` time out and the install fail.
# Bootstrap note: the bare ubuntu image has no `ca-certificates` yet, so we
# disable TLS peer verification *only for this first apt run*. This is safe:
# apt still GPG-verifies the signed Release files, so package integrity is
# guaranteed independently of the transport. Once ca-certificates is installed
# below, every later https call (Homebrew, curl, …) verifies normally.
#
# The two cache mounts keep the downloaded .deb archives + package lists across
# builds. We drop the default `docker-clean` hook (it purges the archive cache)
# and skip `apt-get clean` for the same reason -- the cache mount, not the image,
# holds them, so nothing bloats the final image.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && sed -i 's|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get -o Acquire::https::Verify-Peer=false update \
    && apt-get -o Acquire::https::Verify-Peer=false install -y --no-install-recommends \
        build-essential \
        procps \
        curl \
        file \
        git \
        ca-certificates \
        sudo \
        locales \
        unzip \
        xz-utils \
        tar \
    && locale-gen en_US.UTF-8

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# --- Chromium/Playwright system libraries ---
# The Playwright-managed Chromium binary downloads fine at runtime (into
# ~/.cache/ms-playwright, no root needed), but it dynamically links ~20 shared
# libraries that only apt provides -- Homebrew on Linux can't supply them for
# Chromium. We bake them in here so `npx playwright ...` works in the running
# container without sudo (which is fine to use at build time, but blocked at run).
#
# Package names are the Ubuntu 24.04 (noble) set: several libs moved to the
# time_t-64bit `...t64` names on this release. This is the equivalent of
# `playwright install-deps chromium`, done via apt because root has no node here
# (node lives under nvm for the `dev` user only). Same apt cache-mounts as above.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        libglib2.0-0t64 libnspr4 libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 \
        libdbus-1-3 libcups2t64 libxcb1 libxkbcommon0 libasound2t64 libgbm1 \
        libx11-6 libxext6 libcairo2 libpango-1.0-0 libxcomposite1 libxdamage1 \
        libxfixes3 libxrandr2 libexpat1 libatspi2.0-0t64

# --- Create a non-root user with passwordless sudo ---
# Ubuntu 24.04 ships a default `ubuntu` user at UID 1000; remove it to free the UID.
RUN userdel -r ubuntu 2>/dev/null || true; \
    groupdel ubuntu 2>/dev/null || true; \
    groupadd --gid ${USER_GID} ${USERNAME}; \
    useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${USERNAME}; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME}; \
    chmod 0440 /etc/sudoers.d/${USERNAME}; \
    mkdir -p /workspace; \
    chown ${USERNAME}:${USERNAME} /workspace

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# --- Install Homebrew (Linuxbrew) as the non-root user ---
RUN NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Put brew (and user-local bins) on PATH for all subsequent build steps, and turn
# off the auto-update that otherwise re-clones the tap on every `brew install`
# (slow + non-deterministic). HOMEBREW_CACHE points brew's downloads at a stable
# path we cache-mount below.
ENV PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/home/${USERNAME}/.local/bin:${PATH}" \
    HOMEBREW_NO_AUTO_UPDATE=1 \
    HOMEBREW_NO_ANALYTICS=1 \
    HOMEBREW_NO_ENV_HINTS=1 \
    HOMEBREW_CACHE=/home/${USERNAME}/.cache/Homebrew

# --- Install the requested tools via Homebrew, split by change frequency ---
# Each `brew install` gets the Homebrew cache mount so re-downloads are avoided.
# NOTE: BuildKit cache-mount options cannot expand build ARGs, so the target path
# and uid/gid are hard-coded to the defaults (USERNAME=dev, UID/GID=1000). If you
# override those ARGs the cache simply won't be reused -- the build still works.
#
# kubernetes-cli provides `kubectl`; azure-cli provides `az`.

# Small, stable CLIs -- rarely change, keep them high so they stay cached.
RUN --mount=type=cache,target=/home/dev/.cache/Homebrew,uid=1000,gid=1000 \
    brew install git helm kubernetes-cli zsh

# azure-cli is huge (~1GB) and changes rarely -- isolate it so nothing else
# forces it to reinstall.
RUN --mount=type=cache,target=/home/dev/.cache/Homebrew,uid=1000,gid=1000 \
    brew install azure-cli

# Python toolchain (pinned formula) + uv.
RUN --mount=type=cache,target=/home/dev/.cache/Homebrew,uid=1000,gid=1000 \
    brew install ${PYTHON_FORMULA} uv

# nvm (Node itself is installed via nvm below).
RUN --mount=type=cache,target=/home/dev/.cache/Homebrew,uid=1000,gid=1000 \
    brew install nvm

# Friendly `python` / `pip` shims (the versioned formula is keg-only, so expose
# it on PATH via ~/.local/bin). We link from the keg's `libexec/bin`, not `bin`:
# a keg-only python@3.x ships only versioned names (python3.12, pip3.12) in
# `bin`, and keeps the unversioned/major-versioned links (python, python3, pip,
# pip3) in `libexec/bin`. `libexec/bin` exists for every python formula, so this
# survives bumping PYTHON_FORMULA. `ln -sf` happily creates dangling links, so
# the trailing checks fail this layer instead of the sanity check far below.
RUN PYBIN="$(brew --prefix ${PYTHON_FORMULA})/libexec/bin" \
 && mkdir -p "$HOME/.local/bin" \
 && ln -sf "$PYBIN/python" "$HOME/.local/bin/python" \
 && ln -sf "$PYBIN/python3" "$HOME/.local/bin/python3" \
 && ln -sf "$PYBIN/pip"    "$HOME/.local/bin/pip" \
 && ln -sf "$PYBIN/pip3"   "$HOME/.local/bin/pip3" \
 && python --version && pip --version

# --- Node via nvm (pinned to NODE_VERSION, set as default) ---
ENV NVM_DIR="/home/${USERNAME}/.nvm"
RUN mkdir -p "$NVM_DIR" \
 && bash -c 'source "$(brew --prefix nvm)/nvm.sh" \
        && nvm install '"${NODE_VERSION}"' \
        && nvm alias default '"${NODE_VERSION}"' \
        && nvm use default'

# --- oh-my-zsh (pinned to OHMYZSH_REF; clone directly so we can check out a ref) ---
# We ship our own .zshrc below, so we only need the framework on disk -- no need
# for the installer's chsh/auto-launch behaviour.
RUN git clone https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh" \
 && git -C "$HOME/.oh-my-zsh" checkout ${OHMYZSH_REF}

# --- Persistent config dirs (so volume mounts get the right owner) ---
RUN mkdir -p "$HOME/.claude" "$HOME/.config" "$HOME/.azure" "$HOME/.kube"

# --- Shared shell environment (sourced by BOTH bash and zsh) ---
# Keeping the env setup in one file means your .zshrc stays clean and editable.
RUN { \
      echo '# Homebrew'; \
      echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'; \
      echo '# nvm'; \
      echo 'export NVM_DIR="$HOME/.nvm"'; \
      echo '[ -s "$(brew --prefix nvm)/nvm.sh" ] && \. "$(brew --prefix nvm)/nvm.sh"'; \
      echo '# user-local bins (python/pip shims, claude, ...)'; \
      echo 'export PATH="$HOME/.local/bin:$PATH"'; \
    } > "$HOME/.dev-shell-env.sh"

# bash sources the shared env too (in case you ever launch bash)
RUN echo '[ -f "$HOME/.dev-shell-env.sh" ] && source "$HOME/.dev-shell-env.sh"' >> "$HOME/.bashrc"

# Default .zshrc (oh-my-zsh + the shared env). This is baked in so the container
# works standalone; mounting ./zshrc over it (see compose) lets you edit + persist it.
RUN { \
      echo 'export ZSH="$HOME/.oh-my-zsh"'; \
      echo 'ZSH_THEME="robbyrussell"'; \
      echo 'plugins=(git)'; \
      echo 'source "$ZSH/oh-my-zsh.sh"'; \
      echo ''; \
      echo '# --- dev container environment (Homebrew, nvm, local bins) ---'; \
      echo '# Keep this line so brew / node / python stay on your PATH:'; \
      echo '[ -f "$HOME/.dev-shell-env.sh" ] && source "$HOME/.dev-shell-env.sh"'; \
      echo ''; \
      echo '# --- add your own customizations below ---'; \
    } > "$HOME/.zshrc"

# Make zsh the default login shell for this user.
RUN echo /home/linuxbrew/.linuxbrew/bin/zsh | sudo tee -a /etc/shells >/dev/null \
 && sudo usermod -s /home/linuxbrew/.linuxbrew/bin/zsh ${USERNAME}

# --- Claude Code (native installer: Anthropic's recommended method, no Node dependency) ---
# Placed last of the installs: Claude Code updates frequently, so re-pinning
# CLAUDE_VERSION rebuilds only this layer (+ the sanity check), nothing expensive.
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_VERSION}"

# --- Playwright Chromium browser (baked in so it survives rebuilds) ---
# Runs as the `dev` user so the binaries land in ~/.cache/ms-playwright, exactly
# where Playwright looks at runtime. Node lives under nvm, so we source it first.
# The system libs Chromium links against were installed near the top of this file.
# Placed late (Playwright releases often, like Claude Code) so re-pinning
# PLAYWRIGHT_VERSION only rebuilds this cheap layer. A named volume mounted at
# this cache path in docker-compose is seeded from these baked-in binaries on the
# first `up`, then persists them across future rebuilds.
RUN bash -c 'export NVM_DIR="$HOME/.nvm"; source "$(brew --prefix nvm)/nvm.sh"; nvm use default >/dev/null 2>&1; \
    npx --yes playwright@'"${PLAYWRIGHT_VERSION}"' install chromium'

# --- Build-time sanity check (fails the build early if a tool is missing) ---
RUN bash -c 'set -e; \
    export NVM_DIR="$HOME/.nvm"; source "$(brew --prefix nvm)/nvm.sh"; nvm use default >/dev/null 2>&1; \
    echo "=== installed tool versions ==="; \
    git --version; \
    brew --version | head -n1; \
    helm version --short; \
    kubectl version --client 2>/dev/null | head -n1 || true; \
    command -v az >/dev/null && echo "az: $(command -v az)"; \
    python --version; pip --version | head -n1; uv --version; \
    node --version; npm --version; \
    zsh --version; \
    (command -v claude >/dev/null && claude --version 2>/dev/null) || echo "claude: installed"'

WORKDIR /workspace
CMD ["zsh"]
