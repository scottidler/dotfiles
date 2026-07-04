# .zshenv — sourced by ALL zsh invocations (login, interactive, non-interactive, scripts).
# Keep this minimal: only env that must be present everywhere, incl. cron and tool-call shells.

# rust/cargo toolchain on PATH for non-interactive shells
if [ -f "$HOME/.cargo/env" ]; then
    . "$HOME/.cargo/env"
fi

# Age-encrypted secrets (GITHUB_PAT_HOME/WORK/SERVICE, GH_TOKEN, etc.) as env
# vars. ~24ms, negligible even run on every shell. Needed everywhere (not just
# .zshrc) so persona functions like `gh` below actually resolve their tokens in
# non-interactive/agent shells, not just interactive ones.
eval "$(manifest age decrypt ~/repos/scottidler/keep/.secrets)"

# gws default persona = work (scott.idler@tatari.tv); gws-home overrides explicitly.
# Set here (not .zshrc) so the bare `gws` command resolves in non-interactive shells too.
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$HOME/.config/gws/work"

# gh persona switch, mirroring the git includeIf gitdir convention in .gitconfig
# (tatari-tv/ = work, everything else = home). GH_TOKEN always overrides gh's
# stored/switched account, and GH_TOKEN is ambient-exported to the work PAT
# (see keep/.secrets/gh-token.age -> github-pat-work.age), so home must override
# GH_TOKEN itself here, not just GH_CONFIG_DIR. Set here (not .zshrc) so bare
# `gh` resolves correctly in non-interactive shells too.
function gh() {
    case "$PWD" in
        "$HOME"/repos/tatari-tv/*) command gh "$@" ;;
        *) GH_TOKEN="$GITHUB_PAT_HOME" command gh "$@" ;;
    esac
}

# mise shims on PATH everywhere - node/npm and any mise-installed CLI (e.g. the
# Pi agent, npm:@earendil-works/pi-coding-agent) must resolve in non-interactive
# shells too. Full `mise activate zsh` (cd-triggered version-switch hooks) stays
# interactive-only in .shell-exports.d/mise.env - only the shim PATH is needed here.
export MISE_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/mise"
export MISE_DATA_DIR="$MISE_HOME"
export PATH="$MISE_HOME/bin:$PATH"

# sccache wrapper for cargo builds - otto ci / cargo build run directly by an
# agent (not through an interactive shell) still need the compiler cache.
if hash sccache 2>/dev/null; then
    export RUSTC_WRAPPER=$(which sccache)
    export SCCACHE_SERVER_PORT=4227
fi

# Never write __pycache__/*.pyc anywhere. Keeps source/skill dirs clean; the
# import-speed cost is negligible for the short-lived scripts run here.
export PYTHONDONTWRITEBYTECODE=1
