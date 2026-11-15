# Handoff: lappy LAN vs Tailscale routing

Branch: main

Written 2026-11-15 from a session on lappy (`ltl-7007.lan`, 10.10.10.13). All changes were made on lappy. Nothing on ripr was changed.

## Next action

1. Push lappy's dotfiles commit `0ae53d1`. Lappy's `~/repos/scottidler/dotfiles` main is `[ahead 1]` and unpushed. Then pull it here on ripr.
2. The first time lappy is away from home, verify the travel path (see "Not verified" below).

## Goal (Scott's words)

> use the local .lan when my laptop is home. prefer that connectivity. ONLY use tailscale when I am traveling and the laptop is OUT of my home network.

SSH must work both ways between lappy and ripr by `.lan` name.

## Root cause

`ssh ltl-7007.lan` from ripr hung. Lappy got the request over Wi-Fi but sent its replies into the Tailscale tunnel. ripr then saw replies from a different address than the one it dialed and dropped them.

The break needed both of these changes (from the `tailscaled` journals on both hosts):

| When | Host | Change |
|---|---|---|
| 2026-10-25 16:23 | ripr | `EditPrefs: AdvertiseRoutes=[10.10.10.1/32 10.10.10.11/32]` |
| 2026-11-06 14:19 | lappy | `sudo timeout 900 tailscale login --accept-routes`, run over SSH from 10.10.10.11 (ripr). This created a new profile with `ra=true` (accept routes). It had been `ra=false` since 2026-06-11. |

With `ra=true`, lappy installs ripr's two routes in Tailscale's table 52. Table 52 is looked up at priority 5270, before the normal routing table (`main`) at 32766. So `10.10.10.11` went out `tailscale0`, even at home.

## What was done on lappy

- **Routing rule:** `ip rule add to 10.10.10.0/24 lookup main suppress_prefixlength 0 priority 4999`
  - At home, the `main` table has 10.10.10.0/24 on `wlp2s0` (Wi-Fi), so LAN traffic stays on Wi-Fi.
  - `suppress_prefixlength 0` makes the rule ignore the default route. Away from home, `main` has no 10.10.10.x route, so the rule matches nothing and table 52 (`tailscale0`) carries the traffic.
  - An earlier version at priority 5000 had no `suppress_prefixlength`. Away, its default route would have sent 10.10.10.x to the hotel gateway. That rule was deleted.
- **Persistence:** `/etc/systemd/system/lan-route-priority.service` is a oneshot unit, `enabled` and `active`. It adds the rule only if priority 4999 is missing, so restarts are safe. `ExecStop` deletes the rule.
- **Dotfiles:** commit `0ae53d1` in `~/repos/scottidler/dotfiles` adds the `script: lan-route-priority` block to `manifest.yml`. The block writes the unit with `sudo tee`, then runs `daemon-reload` and `enable --now`. It follows the same pattern as the `udev-uinput` block. The installed unit is byte-identical to the manifest's version (`cmp` passed).
- **Tailscale prefs: unchanged.** Lappy still has `accept-routes=true`, and ripr still advertises both routes. Both are needed for the away path.

## Verified (2026-11-15, lappy at home)

- From lappy, `ssh ripr.lan hostname` returned `ripr`.
- From ripr, `ssh ltl-7007.lan hostname` returned `ltl-7007`.
- On lappy, `ip route get 10.10.10.11` and `ip route get 10.10.10.1` both returned `dev wlp2s0`.
- On lappy, `ip route show table 52 | grep 10.10.10` returned `10.10.10.1 dev tailscale0` and `10.10.10.11 dev tailscale0`.
- On ripr, `ip route get 10.10.10.13` returned `dev enp174s0`. ripr has `RouteAll: false` and needs no rule.

## Not verified

- **The travel path.** I couldn't test it from home. When lappy is away, run these on lappy:
  - `ip rule | grep ^4999:`: the rule should be present.
  - `ip route get 10.10.10.11`: expect `dev tailscale0`.
  - `ssh ripr.lan hostname`: expect `ripr`. If `ripr.lan` doesn't resolve away from home, `ssh 10.10.10.11` is the fallback.
- **The manifest block on other hosts.** It runs on every host that runs the manifest, including ripr and desk. There it adds the same rule. Each of those hosts has a 10.10.10.0/24 route on its LAN NIC, so traffic should stay on the LAN. I didn't test the block on ripr or desk.

## Known limits

- Away from home, Tailscale carries only the router (`.1`) and ripr (`.11`). Desk (`10.10.10.10`) is not advertised, so it isn't reachable by LAN address.
- ripr → lappy by `ltl-7007.lan` works only at home. Away, use lappy's Tailscale address (`100.83.140.72`).

## Open question (not investigated)

- Who ran `tailscale login --accept-routes` on lappy from ripr on 2026-11-06 14:18–14:19, and why? The SSH logins came from 10.10.10.11 with key `SHA256:H0/DLYPPPvbAFCJedpMR65qrPr2lc4GDojz84xmWAjI`. To find the session that ran it, use `session-recall` (clyde) on ripr and search for `accept-routes` around that time.

## Undo

On lappy:

```
sudo systemctl disable --now lan-route-priority.service   # ExecStop deletes the 4999 rule
sudo rm /etc/systemd/system/lan-route-priority.service
sudo systemctl daemon-reload
```

Then revert `0ae53d1` in dotfiles.

## Suggested skills

- `session-recall`: find the 2026-11-06 session that turned on `--accept-routes`.
- `dotfiles`: for any further changes to the manifest.
