# .zshenv — sourced by ALL zsh invocations (login, interactive, non-interactive, scripts).
# Keep this minimal: only env that must be present everywhere, incl. cron and tool-call shells.

# rust/cargo toolchain on PATH for non-interactive shells
if [ -f "$HOME/.cargo/env" ]; then
    . "$HOME/.cargo/env"
fi

# gws default persona = work (scott.idler@tatari.tv); gws-home overrides explicitly.
# Set here (not .zshrc) so the bare `gws` command resolves in non-interactive shells too.
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$HOME/.config/gws/work"
