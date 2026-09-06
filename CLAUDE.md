# dotfiles

Personal OS/shell provisioning repo, driven by [`manifest`](https://github.com/scottidler/manifest) (a Rust CLI that renders `manifest.yml` into a Bash install script). This is the primary/base manifest repo (shell, symlinks, packages, tools); the companion private repo `scottidler/keep` layers secrets and private config on top.

## How it works

`manifest.yml` -> `manifest` CLI -> generated Bash -> piped to `bash`.

```bash
cd ~/repos/scottidler/dotfiles
manifest | bash          # run everything
manifest -l 'HOME/.zsh*' | bash   # filter one section with a fuzzy pattern
```

Section flags (`-l` link, `-a` apt, `-g` github, `-p` ppa, `-c` cargo, etc.) each accept fuzzy patterns (glob/regex/prefix/contains) matched against item lines, not just names.

## Layout

| Path | Purpose |
|------|---------|
| `manifest.yml` | the spec: every section below |
| `HOME/` | tree mirrored into `$HOME` by the `link:` section (recursive) |
| `layout` | legacy Python provisioning script, superseded by `manifest` (kept for reference) |
| `Dockerfile` | container for testing provisioning in isolation |
| `docs/` | misc setup notes (e.g. `gpg-pinentry-ssh.md`) |
| `motd` | message-of-the-day script |

## manifest.yml sections in use here

| Section | Installs via |
|---------|--------------|
| `link` | symlinks `HOME/*` into `$HOME` |
| `ppa` | apt PPAs (Debian/Ubuntu) |
| `pkg` | packages valid for both apt and dnf |
| `apt` / `dnf` | distro-specific packages |
| `pip3` / `uv-tool` | Python installs |
| `npm` | npm globals |
| `cargo` | Rust crates |
| `github` | clone + build + link GitHub repos |
| `script` | freeform install steps that don't fit another section |

(`flatpak` and `git-crypt` sections exist in the manifest schema but aren't currently used here.)

## Conventions

- Edit files under `HOME/`, never edit the symlinked target in `$HOME` directly — the repo copy is the source of truth.
- `~/.config/manifest/identity.txt` (age x25519 key) is required to decrypt secrets; it lives outside this repo, backed up in 1Password. Actual secrets live in `scottidler/keep`, not here.
- Re-running `manifest | bash` is idempotent; safe to re-run after editing `manifest.yml`.

## Relationship to other manifest repos

- `scottidler/keep`: private secrets (age-encrypted) + private plaintext config, layered on top of this repo via its own `manifest.yml`.
- `scottidler/claude`: Claude Code config (skills, agents, rules), also manifest-managed, deployed independently.
