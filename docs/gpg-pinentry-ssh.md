# GPG Pinentry Over SSH / Headless Sessions

## The Problem

When Claude Code (or any non-interactive subprocess) runs `git commit`, it spawns a process with no TTY and no DISPLAY. Both common pinentry programs fail in this context:

- `pinentry-gnome3` - requires a graphical display, fails over SSH / in subprocesses
- `pinentry-curses` - requires a TTY, fails in headless subprocesses

The result: git commit hangs or errors waiting for a passphrase prompt that can never appear.

## The Fix

Two settings together solve this permanently:

**`~/.gnupg/gpg-agent.conf`**
```
allow-loopback-pinentry
```

**`~/.gnupg/gpg.conf`**
```
pinentry-mode loopback
```

### Why this works

With `pinentry-mode loopback`, gpg-agent never invokes the external pinentry program. Instead:

- **Cache warm** (within `default-cache-ttl`): agent returns the cached passphrase directly - nothing is prompted, commits just work.
- **Cache cold, interactive terminal**: gpg prompts inline ("Enter passphrase:") via its own stdin - no curses, no GUI dialog.
- **Cache cold, headless subprocess**: fails fast with an error instead of hanging forever waiting for a pinentry that can never display.

The `pinentry-program` line in `gpg-agent.conf` is kept as a dead fallback for edge cases (key generation, etc.) but is not invoked for normal signing operations.

## Cache TTL

The cache is already configured generously:

```
default-cache-ttl 86400    # 24 hours
max-cache-ttl 604800       # 7 days
```

Enter your passphrase once in an interactive session at the start of the day and Claude Code's commits will work all day without prompting.

## Shell Config

`~/.shell-exports` and `~/.shell-exports.d/gpg.env` handle the interactive-session side:

```bash
export GPG_TTY=$(tty)
gpg-connect-agent UPDATESTARTUPTTY /bye >/dev/null 2>&1
```

These update the agent's stored TTY whenever a new interactive shell opens, so pinentry knows where to prompt when the cache is cold. These only apply to interactive sessions - they do not help headless subprocesses, which is why the loopback config above is the real fix.
