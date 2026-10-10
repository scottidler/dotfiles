# New machine bootstrap: blank Ubuntu to a working setup

Steps to take a fresh Ubuntu 26.04 install to a working setup: `scottidler/{dotfiles,keep,claude}` deployed, shells, editor, terminal, Rust tools, secrets, Claude Code.

Source: the ripr.lan bring-up on 2026-10-04 (session `15c13695-95bd-46ed-819d-1dac9acbb6e7`), plus a read of the three manifests and the GitHub release state on 2026-10-04. Every "Gap" below is something that broke or needed hand-fixing on ripr.

Part 1 is the sequence as it works today. Part 2 is the list of gaps. Part 3 proposes a bootstrap that removes most of Part 1.

---

## Part 1: The sequence

### Phase 0: Installer

- Ubuntu 26.04 desktop, username `saidler`, hostname `<name>` (DNS gives it `<name>.lan`).
- Leave Secure Boot on. Note: it puts the kernel in `integrity` lockdown, which blocks amdgpu debugfs (this is what hid the display chroma format on ripr). That only matters for display debugging.

### Phase 1: First boot, at the console

The only step that needs a keyboard on the machine. After it, everything else runs over ssh from desk.

```bash
sudo apt update && sudo apt install -y openssh-server git curl ca-certificates jq zsh
sudo systemctl enable --now ssh
```

- `openssh-server`: Ubuntu desktop doesn't ship it.
- `jq` is here because the manifest's release-download scripts use it.

### Phase 2: SSH, from desk

```bash
# desk -> new: authorize desk's key (prompts for the new machine's password once)
ssh-copy-id -i ~/.ssh/identities/home/id_ed25519.pub <name>.lan

# ship the identity tree (home, work, wohl-nanw) with its permissions
tar -C ~/.ssh -czf - identities | ssh <name>.lan 'mkdir -p -m 700 ~/.ssh && tar -C ~/.ssh -xzf -'

# ship the age identity (decrypts every keep secret)
ssh <name>.lan 'mkdir -p -m 700 ~/.config/manifest'
scp ~/.config/manifest/identity.txt <name>.lan:.config/manifest/identity.txt
ssh <name>.lan 'chmod 600 ~/.config/manifest/identity.txt'

# new -> desk and lappy: pre-trust host keys
ssh <name>.lan 'ssh-keyscan -H desk.lan ltl-7007.lan >> ~/.ssh/known_hosts'
```

- Piping the tar over ssh avoids leaving a key tarball on disk. On ripr, `~/.ssh/identities.tar.gz` was left behind.
- Return-direction login (new -> desk) works once Phase 4 links `~/.ssh/config`, which picks `identities/home/id_ed25519`.
- `identity.txt` is also in 1Password, if desk isn't reachable.

### Phase 3: Install manifest without Rust

`scottidler/manifest` publishes prebuilt binaries: `v0.4.6` has `manifest-v0.4.6-linux-amd64.tar.gz` plus `.sha256`. Use that, not `cargo install`.

```bash
mkdir -p ~/.local/bin
url=$(curl -fsSL https://api.github.com/repos/scottidler/manifest/releases/latest \
  | jq -r '.assets[] | select(.name | test("linux-amd64.tar.gz$")) | .browser_download_url')
curl -fsSL "$url" | tar -xz -C ~/.local/bin
~/.local/bin/manifest --version
```

- On ripr, rustup plus `cargo install --git` cost a toolchain download and a compile, and gave `--version` = `650a43e` (cargo's git checkout has no tags).
- Verified 2026-10-04: the tarball holds a single `manifest` binary at its root, and `sha256sum -c` against the `.sha256` asset passes.
- Later, once Rust is in (Phase 8), clone `scottidler/manifest` and `cargo install --path .` to track main.

### Phase 4: Dotfiles links

```bash
mkdir -p ~/repos/scottidler
git clone https://github.com/scottidler/dotfiles ~/repos/scottidler/dotfiles
cd ~/repos/scottidler/dotfiles
manifest -l '*' | bash
git remote set-url origin git@github.com:scottidler/dotfiles
```

- HTTPS works because the repo is public, so this step needs no keys.
- The linker backs up colliding stock files (`.bashrc`, `.profile`, `.zshenv`) to `*.orig`. On ripr: 79 links, 0 errors.
- From this point, `~/.cargo/config.toml` is linked and needs `mold` and `sccache`. **Any `cargo install` fails until Phase 8 is done** (see Gap 3).

### Phase 5: Shell

```bash
chsh -s /usr/bin/zsh
```

- Applies to new logins only. A GNOME session keeps `SHELL=/bin/bash` until you log out and back in. Use `ps -p $$ -o comm=` to see the shell that's actually running.
- zsh startup needs `antidote` (Phase 9). Until then `.zshrc` prints a guard warning instead of failing (commit `5e514fe`).

### Phase 6: System settings (manifest `script:` entries)

Run the ones that need sudo or system state first, from a desktop terminal on the new machine (`gsettings` needs the session bus):

```bash
cd ~/repos/scottidler/dotfiles
manifest -s passwordless-sudo | bash   # prompts once, then /etc/sudoers.d/saidler
manifest -s disable-ipv6 | bash       # fixed ~200 ms per new connection on ripr
manifest -s gnome-no-idle-dim | bash  # power: no idle dim, profile balanced
manifest -s firefox-opt | bash        # Mozilla tarball in /opt, snap removed and pinned out
manifest -s nerd-fonts | bash         # FiraCode Nerd Font into ~/.local/share/fonts
manifest -s terminal-font | bash      # FiraCode Nerd Font 14 in Ptyxis / GNOME Terminal
```

- `disable-ipv6` exits `1` on any host whose Wi-Fi isn't named `wlp2s0` (desk's name is hardcoded). The other keys still apply (Gap 6).
- Power is only partly captured (Gap 8).

### Phase 7: apt packages

```bash
manifest -a '*' | bash
```

- The `apt:` block always runs `sudo apt update && sudo apt upgrade -y` first, even when scoped to one package.
- It's desk-shaped (gimp, steam-adjacent items, PPAs such as `graphics-drivers/ppa`). With `allow_errors: False` the first failure stops the run. To control the order, scope it by pattern (`manifest -a kitty | bash`).
- Packages that later phases depend on: `mold`, `cmake`, `libclang-dev`, `build-essential`, `pkg-config`, `libssl-dev`, `golang`, `kitty` (and `kitty-terminfo`), `lua5.1`, `luarocks`, `speedtest-cli`.

### Phase 8: Rust toolchain

```bash
manifest -s rust | bash      # rustup
. ~/.cargo/env
manifest -s sccache | bash   # enables the sccache user unit
cargo install sccache --locked
```

- Order matters: `mold` (Phase 7) and `sccache` must be in place before any other `cargo install`, because the linked `~/.cargo/config.toml` names both.
- On ripr, `sccache` and `deno` failed with `cannot find 'ld'` until `mold` was installed.

### Phase 9: cargo crates and GitHub repos

```bash
manifest -c '*' | bash   # 30 crates; deno and eza need --locked (Gap 4)
cargo install deno eza --locked
manifest -g '*' | bash   # clones to ~/repos/<owner>/<repo>, cargo install --path, links
```

- The cargo batch took `17m 24s` on ripr's 32-core Threadripper.
- `github:` installs antidote, oh-my-zsh and its plugins, `scottidler/nvim` (linked to `~/.config/nvim`), aka, git-tools, rkvr, helpful (links `~/bin/speedtest` and friends) and more.
- `helpful/bin/tab3` is a dangling link upstream; the linker skips it and carries on.

### Phase 10: Editor

- **Install under `/opt`**, following the `firefox-opt` pattern: upstream's `nvim-linux-x86_64.tar.gz` from the latest stable release (`v0.12.5` on 2026-10-04), extracted to `/opt/nvim-linux-x86_64`, then `sudo ln -sf /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim`. A re-run replaces the tree, which is also the upgrade path. This would be a new `script: neovim-opt` entry (Gap 7).
- **Why not apt:** apt's candidate is `0.11.6`, and avante's version check failed on 0.11.x (session `f0cba4e1`, 2026-09-01). The `apt: neovim` entry (`manifest.yml:171`) should go.
- **Desk today:** `v0.12.5` sits in the home directory instead, at `~/.local/opt/neovim/`, linked from `~/.local/bin/nvim`. That 2026-09-01 session used home because it couldn't answer a sudo prompt. `~/.local/bin` comes before `/usr/local/bin` on PATH, so that link has to be removed when desk moves to `/opt`.
- **Config:** `scottidler/nvim` (LazyVim: `init.lua`, `lazy-lock.json`, `lazyvim.json`) is linked by Phase 9. The first `nvim` launch syncs plugins from `lazy-lock.json`.
- **System editor** (for visudo and sudoedit): `sudo update-alternatives --install /usr/bin/editor editor /usr/local/bin/nvim 100 && sudo update-alternatives --set editor /usr/local/bin/nvim`. `EDITOR`/`VISUAL` come from the dotfiles.
- **Plugin deps:** `lua5.1` and `luarocks` come from apt (Phase 7).

### Phase 11: keep (secrets and private config)

```bash
git clone git@github.com:scottidler/keep ~/repos/scottidler/keep   # Phase 9 also clones it
cd ~/repos/scottidler/keep
manifest -l '*' -s '*' | bash
```

- With `identity.txt` from Phase 2, shell startup decrypts the `secrets.env` list. On ripr: `57` exports.
- `HOME/` links into `~/Claude/writing/voice` are absolute and desk-only by design, so they dangle elsewhere. That's expected.
- `~/Claude` itself arrives through Syncthing (`manifest -s syncthing`), and has to be paired with desk by hand.

### Phase 12: Claude Code and the claude repo

```bash
curl -fsSL https://claude.ai/install.sh | bash     # native installer -> ~/.local/bin/claude
git clone git@github.com:scottidler/claude ~/repos/scottidler/claude
cd ~/repos/scottidler/claude
manifest | bash
```

- Claude Code itself isn't in any manifest (Gap 5).
- `mcp-servers` registers 9 MCP servers, and needs their binaries on PATH first: `persona`, `clyde`, `marquee`, `slack`, `sb`, `gslides-mcp`. See Phase 13.
- `gslides-creds` needs a `gws` home login already in place.
- `pipx:` needs `pipx`, and `uv-tool:` (in dotfiles) needs `uv`. Neither is installed by any manifest; desk's `uv` is a hand install at `~/.local/bin/uv` (Gap 5).

### Phase 13: Fleet and workflow CLIs

None of these are in a manifest. The release state as of 2026-10-04:

| Tool | Repo | Prebuilt linux-amd64 |
|---|---|---|
| clyde | tatari-tv/clyde | yes, v0.25.9 |
| marquee | tatari-tv/marquee | yes, v1.23.6 |
| sdv | tatari-tv/sdv | yes, v0.5.6 |
| sb | scottidler/second-brain | yes, v0.15.11 |
| bump | scottidler/bump | yes, v0.4.2 |
| shepherd | tatari-tv/shepherd | release exists, no linux-amd64 asset |
| slack, persona, otto, pagerduty, herdr | tatari-tv/* | no release; `cargo install --path` from a clone |

- tatari-tv repos are private, so clone them with the work identity (the `clone` tool picks the key by org).

### Phase 14: Desktop leftovers (by hand)

- Firefox: sign in to Sync. The obsidian-borg extension goes in through `/etc/firefox/policies/policies.json`. On a non-desk host, the endpoint can't be set to `http://desk.lan:8181` because of the `options.js` port bug (Gap 10).
- Log out and back in (fixes `$SHELL` and picks up the fonts).
- Check `/var/run/reboot-required`.

### Verification

```bash
for c in manifest cargo nvim zsh kitty go deno eza clyde sb claude; do printf '%-9s %s\n' $c "$(command -v $c || echo MISSING)"; done
zsh -ic exit 2>&1 | grep -v '^$'      # expect no output
bash -ic exit 2>&1 | grep -v 'job control'
ssh desk.lan hostname                  # expect: desk
git -C ~/repos/scottidler/dotfiles remote -v | grep -q git@ && echo ssh-remote-ok
```

---

## Part 2: Gaps found on ripr

| # | Gap | Evidence | Fix |
|---|---|---|---|
| 1 | No bootstrap: manifest needs Rust needs manifest | ripr needed rustup plus a compile just to get `manifest`, which then reported `650a43e` | Phase 3 release download, wrapped in `bootstrap.sh` (Part 3) |
| 2 | `allow_errors: False` plus desk-shaped sections | A full `manifest \| bash` stops at the first desk-only failure | Host profiles (Part 3) |
| 3 | `link:` lands `~/.cargo/config.toml` before `mold` and `sccache` exist | `cannot find 'ld'` on `sccache` and `deno` | Bootstrap installs `mold` early, and `sccache` from its own prebuilt release |
| 4 | `cargo:` can't pass `--locked` | `deno` and `eza` (`palette`, 34 errors) failed until run with `--locked` | Per-item flags in manifest's `cargo:` section, or move both to the release path |
| 5 | Not in any manifest: Claude Code, `uv`, `pipx`, neovim tarball, fleet CLIs | All found as hand installs on desk (`~/.local/bin/uv`, `~/.local/opt/neovim`) | Add `script:` entries, or the `release:` section (Part 3) |
| 6 | `disable-ipv6` hardcodes `wlp2s0` | Exit `1` on ripr (`cannot stat .../wlp2s0/...`) | Drop the per-interface line; `all` and `default` already cover it |
| 7 | apt neovim is too old, and desk's neovim install isn't reproducible | apt `0.11.6` failed avante's check; desk's `0.12.5` was a hand install in `~/.local/opt` | `script: neovim-opt`: upstream tarball into `/opt`, linked from `/usr/local/bin/nvim`; drop `apt: neovim` |
| 8 | Power settings only partly captured | Desk reads: `idle-delay 0`, `sleep-inactive-ac-type 'nothing'`, `color-scheme 'prefer-dark'`, none of which a manifest sets. Desk also reads `idle-dim true`, the opposite of what `gnome-no-idle-dim` sets (read from the sandbox, so not verified against the live session) | A `gnome-settings` script that sets all of them |
| 9 | Kitty has no config off desk, and apt is behind upstream | ripr: no `kitty.conf`; apt `0.45.0` vs upstream `0.49.2` | Track `kitty.conf` in `HOME/.config/kitty/`; decide whether to use upstream's installer |
| 10 | obsidian-borg `options.js:21` uses `url.host` (port included) in `permissions.contains` | Firefox match patterns don't support ports, so Save refuses `http://desk.lan:8181` | Use `url.hostname` in second-brain, then rebuild and re-sign |
| 11 | A secret-shaped file is left in `~` after a key copy | `~/.ssh/identities.tar.gz` stayed on ripr | Phase 2's tar-over-ssh pipe |

---

## Part 3: Recommended bootstrap

### Goal: one command, typed once, in a desktop terminal on the new machine

```bash
wget -qO- https://raw.githubusercontent.com/scottidler/dotfiles/main/bootstrap.sh | bash
```

**Why `wget` and not `curl`:** ripr's installer log (`/var/log/installer/initial-status.gz` plus apt history) shows a stock 26.04 desktop ships `wget`, `jq`, `sudo-rs`, `xz-utils` and `unzip`, but **not `curl`, `git` or `openssh-server`**. The `curl` on ripr came from the hand-run `apt install`. So `wget | bash` needs no prerequisite at all. `curl | bash` needs `sudo apt install curl` first.

**What it needs from you:** prompts, not commands.
- Your sudo password, once. The script then installs `passwordless-sudo` first, so later steps don't ask again.
- desk's password, once. Desk's sshd accepts password auth (a probe on 2026-10-04 returned `Permission denied (publickey,password)`). The script opens one ssh ControlMaster connection (a single shared login that later scp and ssh calls reuse) to `desk.lan`, and pulls everything over it.
- All prompts read from `/dev/tty`, because under `| bash` stdin is the script itself.

**What it does, in order, idempotent, guard-and-report on every step:**

1. Prerequisites, before anything else: `sudo apt update && sudo apt install -y curl git vim openssh-server zsh ca-certificates rsync build-essential pkg-config libssl-dev mold cmake libclang-dev`, then enable `ssh`. Every later step assumes these are present.
   - `curl` and `git`: every download and clone after this step.
   - `vim`: a working editor (for visudo and sudoedit) until neovim lands in step 5.
   - `openssh-server`: desk -> new logins.
   - `zsh`: the login shell.
   - `build-essential`, `pkg-config`, `libssl-dev`, `mold`, `cmake`, `libclang-dev`: the build deps that broke `sccache` and `deno` on ripr.
   - `ca-certificates`, `rsync`: needed by later steps.
2. Pull from desk over the shared connection: `~/.ssh/identities/` (tar over ssh, never a tarball on disk) and `~/.config/manifest/identity.txt` (mode 600). Seed `known_hosts` for desk and lappy. Append `identities/home/id_ed25519.pub` to the new machine's `authorized_keys`, so desk -> new works right away (desk already logs in with that key).
3. Download the `manifest` release binary into `~/.local/bin`, checking the `.sha256`.
4. Clone dotfiles, keep and claude into `~/repos/scottidler/` over SSH (the keys are present now, so the remotes come out right the first time).
5. Run the dotfiles phases in the Part 1 order: links, `chsh` to zsh, system scripts, apt, rustup and `sccache`, cargo (`deno` and `eza` with `--locked`), github repos, neovim, fonts, terminal font.
6. Run keep's links, install Claude Code, then run the claude manifest.
7. Install the fleet CLIs from their releases, and clone and build the ones with no release.
8. Print a summary: each step `ok` or `FAILED <step>: <reason>`, with the log path, and the list of by-hand logins.

Every step logs to `~/.cache/bootstrap/<step>.log`. A failure stops only its own step. Re-running the same command skips what's already done.

**Still by hand (logins, not commands):** log out and back in (fixes `$SHELL` and picks up fonts), Firefox Sync, Syncthing pairing with desk, `gws` home login, `marquee login`, 1Password.

**Where it lives:** `bootstrap.sh` at the dotfiles root. Not under `docs/`, and not in `bin/`, because it has to be fetchable from a stable raw URL.

### Host profiles in manifest

- The sections are desk-shaped, and `keep/manifest.yml` already names the gap ("manifest has no host-scoping").
- Proposal: a top-level `profiles:` map (`base`, `desktop`, `desk-only`), each listing the item names it includes, plus `manifest --profile base,desktop`. Then a new machine runs `base,desktop` and never touches `swap-tuning`, `sweep-repos-watchdog` or the desk-specific PPAs.

### A `release:` section in manifest

- 30 `scottidler` Rust repos already publish `linux-amd64` tarballs through the shared `rust-cli-release` workflow (including manifest, aka, slam, nerf, kat, cidr, workweek, second-brain and bump). The `github:` section still compiles each one with `cargo install --path .`.
- Proposal: `release: { scottidler/aka: aka, tatari-tv/clyde: clyde, ... }`, meaning download the latest `*-linux-amd64.tar.gz`, check the sha256, and install to `~/.local/bin`. That covers most tools without a compile, and rustup becomes a development dependency only.
- Repos whose assets don't match `linux-amd64` (git-tools: `git-tools-v0.4.2-linux.tar.gz`, dashify, rkvr, requote) need their workflow moved to the shared one, or a per-item pattern.
- The existing `latest()` helper in `manifest/bin/latest.sh` already does the download-and-extract half.

### Resulting sequence

1. Install Ubuntu, log in to the desktop, open a terminal.
2. `wget -qO- .../bootstrap.sh | bash`, then answer two password prompts.
3. Do the by-hand logins.

`bootstrap.sh` can ship before profiles or the `release:` section exist: it scopes each manifest call itself and builds from source where there's no release. Those two manifest features only make it shorter and quicker later.
