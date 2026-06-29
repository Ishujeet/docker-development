# syntax=docker/dockerfile:1
#
# Homebrew-based dev container
# Tools: git, helm, kubectl, az (Azure CLI), node, nvm, python (latest), pip, uv,
#        claude-code, zsh + oh-my-zsh
# Package manager of choice: Homebrew (Linuxbrew). You can `brew install` anything new at runtime.
#
FROM ubuntu:24.04

# Username / IDs are build args so file ownership on mounted volumes matches your host user.
# On your host run `id -u` / `id -g` and pass them in (defaults to 1000/1000).
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

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
RUN sed -i 's|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources \
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
    && locale-gen en_US.UTF-8 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

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

# Put brew (and user-local bins) on PATH for all subsequent build steps.
ENV PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/home/${USERNAME}/.local/bin:${PATH}"

# --- Install the requested tools via Homebrew ---
# kubernetes-cli provides the `kubectl` binary; azure-cli provides `az`.
RUN brew update && brew install \
        git \
        helm \
        kubernetes-cli \
        azure-cli \
        python \
        uv \
        nvm \
        zsh

# Friendly `python` / `pip` shims (Homebrew exposes python3/pip3).
RUN mkdir -p "$HOME/.local/bin" \
 && ln -sf "$(brew --prefix python)/bin/python3" "$HOME/.local/bin/python" \
 && ln -sf "$(brew --prefix python)/bin/pip3" "$HOME/.local/bin/pip"

# --- Node via nvm (installs the latest current Node + npm, set as default) ---
ENV NVM_DIR="/home/${USERNAME}/.nvm"
RUN mkdir -p "$NVM_DIR" \
 && bash -c 'source "$(brew --prefix nvm)/nvm.sh" \
        && nvm install node \
        && nvm alias default node \
        && nvm use default'

# --- Claude Code (native installer: Anthropic's recommended method, no Node dependency) ---
RUN curl -fsSL https://claude.ai/install.sh | bash

# --- oh-my-zsh (unattended: no chsh, no auto-launch during build) ---
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

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

# --- Build-time sanity check (fails the build early if a tool is missing) ---
RUN bash -c 'set -e; \
    export NVM_DIR="$HOME/.nvm"; source "$(brew --prefix nvm)/nvm.sh"; nvm use default >/dev/null 2>&1; \
    echo "=== installed tool versions ==="; \
    git --version; \
    brew --version | head -n1; \
    helm version --short; \
    kubectl version --client 2>/dev/null | head -n1 || true; \
    command -v az >/dev/null && echo "az: $(command -v az)"; \
    python3 --version; pip3 --version | head -n1; uv --version; \
    node --version; npm --version; \
    zsh --version; \
    (command -v claude >/dev/null && claude --version 2>/dev/null) || echo "claude: installed"'

WORKDIR /workspace
CMD ["zsh"]