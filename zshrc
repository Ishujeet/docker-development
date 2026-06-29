export ZSH="$HOME/.oh-my-zsh"

# Theme (try: agnoster, bira, robbyrussell, ...)
ZSH_THEME="robbyrussell"

# oh-my-zsh plugins for the tools baked into this container.
# (kubectl/helm/npm add completions + handy aliases.)
plugins=(git kubectl helm npm docker docker-compose)

source "$ZSH/oh-my-zsh.sh"

# --- dev container environment (Homebrew, nvm, local bins) ---
# Keep this line so brew / node / python stay on your PATH:
[ -f "$HOME/.dev-shell-env.sh" ] && source "$HOME/.dev-shell-env.sh"

# --- history ---
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS

# --- add your own customizations below ---

# general
alias ll='ls -lah'
alias la='ls -A'
alias ..='cd ..'
alias ...='cd ../..'

# git
alias gs='git status'
alias gl='git log --oneline --graph --decorate'
alias gd='git diff'

# kubernetes
alias k='kubectl'
alias kg='kubectl get'
alias kd='kubectl describe'
alias kns='kubectl config set-context --current --namespace'

# python / uv — Homebrew python is PEP 668 "externally managed", so work in a venv:
alias venv='uv venv && source .venv/bin/activate'

# nvm helper (nvm itself is loaded via .dev-shell-env.sh)
alias node-lts='nvm install --lts && nvm use --lts'
