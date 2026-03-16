#export ZSH_DEBUG_LOG=/tmp/zsh_debug.log
#exec 3>$ZSH_DEBUG_LOG
#trap 'echo "TRACE: ${(%):-%x}:${LINENO}: $ZSH_DEBUG_LOG: ${1:-}" >&3' DEBUG


if [[ -n "$ZSH_PROFILE" ]]; then
    zmodload zsh/zprof
fi

# ============================================================================
# PATH & ENVIRONMENT
# ============================================================================

typeset -U path
path=("$HOME/bin" $path)

# macOS compatibility
gdircolors &>/dev/null && alias dircolors='gdircolors'

setopt clobber
unsetopt nomatch

PROMPT_EOL_MARK=''
ZLE_REMOVE_SUFFIX_CHARS=$' \t\n;&'

# ============================================================================
# ZSH CACHE DIR - required for Oh My Zsh plugins used via Antidote
# ============================================================================
if [[ -d ~/.antidote && ! -v ZSH_CACHE_DIR ]]; then
  export ZSH_CACHE_DIR="$HOME/.cache/oh-my-zsh"
  mkdir -p "$ZSH_CACHE_DIR/completions"
fi

# ============================================================================
# DIRCOLORS
# ============================================================================
[ -f ~/.zsh/zsh-dircolors-solarized/zsh-dircolors-solarized.zsh ] && \
  source ~/.zsh/zsh-dircolors-solarized/zsh-dircolors-solarized.zsh

# ============================================================================
# PLUGINS - Antidote
# ============================================================================

# Make completion functions available before compinit
if [ -d ~/.shell-completions.d/ ]; then
  fpath=(~/.shell-completions.d $fpath)
fi

# Load Antidote
source ~/.antidote/antidote.zsh

# case-insensitive matching so `re<TAB>` hits README.md
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'

# Recompile the bundle if the .txt master-list exists
if [[ -f ~/.zsh_plugins.txt ]]; then
  antidote bundle < ~/.zsh_plugins.txt > ~/.zsh_plugins.zsh
fi

# Only try to source it if the bundle file actually exists
if [[ -f ~/.zsh_plugins.zsh ]]; then
  source ~/.zsh_plugins.zsh
fi

# Enable and control zsh completion cache
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path "$HOME/.zcompcache"

# ============================================================================
# COMINIT (MUST come after plugins, before compdef)
# ============================================================================
autoload -Uz compinit
compinit -C

# Autoload any custom completions
for f in ~/.shell-completions.d/_*(.N); do
  autoload -Uz ${f:t}
done

# ============================================================================
# ZSH HOOKS
# ============================================================================
HIST_SPACING_STYLE="always"
function preexec() {
  if [[ -n "$1" ]]; then
    last_command="$1"
  fi
}
function precmd() {
  if [[ -n "$last_command" ]]; then
    fc -R <(echo "$last_command ")
  fi
}

# ============================================================================
# ALIASES, FUNCTIONS, EXPORTS
# ============================================================================
[ -f ~/.shell-aliases ] && source ~/.shell-aliases
[ -f ~/.shell-exports ] && source ~/.shell-exports
[ -f ~/.shell-functions ] && source ~/.shell-functions

# ============================================================================
# GOOGLE CLOUD / K8s / SSH KEYS
# ============================================================================
[ -f ~/src/google-cloud-sdk/path.zsh.inc ] && source ~/src/google-cloud-sdk/path.zsh.inc
[ -f ~/src/google-cloud-sdk/completion.zsh.inc ] && source ~/src/google-cloud-sdk/completion.zsh.inc
[ -d /usr/local/go/bin ] && path+=("/usr/local/go/bin")
[ -d ~/go/bin ] && path+=("$HOME/go/bin")
hash kubectl 2>/dev/null && source <(kubectl completion zsh)
[ -f ~/.acme.sh/acme.sh.env ] && source ~/.acme.sh/acme.sh.env

# NOTE: it is important for the work to come before the home
eval $(keychain --eval --agents ssh --quiet \
    ~/.ssh/identities/work/id_ed25519 \
    ~/.ssh/identities/home/id_ed25519)

if hash fzf 2> /dev/null; then
    [[ -f /usr/share/fzf/completion.zsh ]] && source /usr/share/fzf/completion.zsh
    [[ -f /usr/share/fzf/key-bindings.zsh ]] && source /usr/share/fzf/key-bindings.zsh
    [[ -f ~/.fzf.zsh ]] && source ~/.fzf.zsh
fi

# Only initialize zoxide in interactive shells to prevent 'command not found: __zoxide_z'
# errors when non-interactive tools (like Claude Code) use 'cd' in bash commands
if [[ -o interactive ]] && hash zoxide 2>/dev/null; then
  eval "$(zoxide init --cmd cd zsh)"
  # uncomment if I suspect something with zoxide is not working correctly
  export _ZO_DOCTOR=0
fi

if hash macchina 2> /dev/null; then
    macchina
fi

if hash starship 2> /dev/null; then
    eval "$(starship init zsh)"
fi

if hash qai 2> /dev/null; then
    eval "$(qai shell-init zsh)"
fi

if hash aka 2>/dev/null; then
    eval "$(aka shell-init zsh)"
fi

if [ -f $HOME/.cargo/env ]; then
    source "$HOME/.cargo/env"
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"                    # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

# ============================================================================
# Put INC_APPEND_HISTORY and safe history settings HERE
### --- SAFER, REAL-TIME ZSH HISTORY --- ###

# File and size
HISTFILE=~/.zsh_history
HISTSIZE=500000
SAVEHIST=500000

# Write each command to history immediately
setopt INC_APPEND_HISTORY    # <- The important one
setopt SHARE_HISTORY
setopt APPEND_HISTORY

# Clean & safe behavior
setopt HIST_SAVE_NO_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_REDUCE_BLANKS
setopt EXTENDED_HISTORY      # timestamps
setopt HIST_IGNORE_SPACE     # commands starting with space not logged

### ---------------------------------------- ###

# ============================================================================
# HISTORY PREFIX SEARCH - must be at very end after all plugins load
# ============================================================================
# Use ZSH built-in prefix search (matches commands STARTING with typed text)
# Bind BOTH escape sequences (normal mode and application mode)
bindkey '^[[A' history-beginning-search-backward
bindkey '^[[B' history-beginning-search-forward
bindkey '^[OA' history-beginning-search-backward
bindkey '^[OB' history-beginning-search-forward

if [[ -n "$ZSH_PROFILE" ]]; then
    zprof
fi

[[ "$TERM" == "" ]] && export TERM=xterm-kitty
