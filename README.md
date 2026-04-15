# dotfiles

## Automation for setting up my OS

* [manifest.yml](./manifest.yml) is the main spec file
* Driven by `manifest` - a Rust binary from [scottidler/manifest](https://github.com/scottidler/manifest)

## How it works

The `manifest` tool reads `manifest.yml` and generates valid bash to provision the system: creating symlinks, installing packages, cloning repos, and running scripts. Pipe to bash to execute.

Run from the repo root:
```
cd ~/repos/scottidler/dotfiles
manifest | bash
```

Note: `~/.config/manifest/identity.txt` is an age private key used for decrypting secrets. It is backed up in 1Password and must be restored manually on a new machine.

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
