# ... an automation repo that sits in $HOME right next to . and ..

## Automation for setting up my OS

* [HOME/.config/manifest/manifest.yml](./HOME/.config/manifest/manifest.yml) is the main spec file
* Driven by `manifest` - a Rust binary from [scottidler/manifest](https://github.com/scottidler/manifest)

## How it works

The `manifest` tool reads `manifest.yml` and generates valid bash to provision the system: creating symlinks, installing packages, cloning repos, and running scripts. Pipe to bash to execute.

Config discovery:
1. `~/.config/manifest/manifest.yml` (XDG default, symlinked from this repo)
2. `./HOME/.config/manifest/manifest.yml` (bootstrap, running from repo root)
3. `./manifest.yml` (legacy fallback)

The repo root is discovered automatically by resolving the config symlink and walking up to find `HOME/`.

### Example: link section
```
$> manifest -l
#!/bin/bash
# generated file by manifest
...
```

### Example: apt section with pattern matching
```
$> manifest -a lib
#!/bin/bash
# generated file by manifest
...
```

Any section flag (`-l`, `-a`, `-g`, etc.) accepts glob patterns to filter items.

## Sections in manifest.yml

| Section | Description |
|---------|-------------|
| `link` | Symlink mappings from `HOME/` into `$HOME` (recursive) |
| `ppa` | PPAs to install on Debian systems |
| `pkg` | Package names valid for both DNF and APT |
| `apt` | Package names specific to APT |
| `dnf` | Package names specific to DNF |
| `pip3` | Items to install via pip3 |
| `pipx` | Items to install via pipx |
| `npm` | Items to install via npm |
| `flatpak` | Items to install via flatpak |
| `cargo` | Rust crates to install via cargo |
| `github` | GitHub repos to clone, build, and link |
| `git-crypt` | Encrypted repos to clone and unlock |
| `script` | Installation scripts for software requiring custom steps |
