# homelab

Fresh Arch or Alpine install → one command → all the apps running, reachable at
`https://<app>.lab` from any device on your Tailscale.

## New server

```
git clone https://github.com/jeebuscrossaint/homelab
cd homelab
sudo ./install.sh
```

(On Alpine, use `doas ./install.sh`, or just run it as root.)

The script:
- installs Docker, Tailscale and git
- makes them start on boot
- logs the machine into Tailscale (it prints a link to open)
- writes `.env`
- sets server stuff: lid closed keeps running, never sleeps, boots to text, and
  the screen turns off when idle
- starts every app

Run it again any time. It skips what's already done. `sudo ./install.sh --pull` also
updates the apps to their newest versions.

**One manual step, only for a new server:** tell Tailscale where `.lab` names live.
Go to the Tailscale admin console, then **DNS**, **Add nameserver**, **Custom**,
and enter the server's Tailscale IP (the script prints it). Turn on **Restrict to
domain** and type `lab`.

## HTTPS: trust the certificate once per device

Caddy makes its own certificates, so each device needs to trust it once. On the
device, open **http://ca.lab** to download `homelab-ca.crt`, then:

- **Arch / Linux:** `sudo trust anchor --store homelab-ca.crt` (Firefox and Chromium pick it up)
- **Windows:** double-click it, **Install Certificate**, **Local Machine**,
  **Trusted Root Certification Authorities**
- **iPhone:** open the downloaded profile in Settings and install it. Then go to
  **General**, **About**, **Certificate Trust Settings** and turn it on.
- **Android:** **Settings**, **Security**, **Encryption & credentials**,
  **Install a certificate**, **CA certificate**

A new server makes a new certificate, so you'd do this again after moving.

## Apps

None of them ask you to log in. That's fine because they only listen on the Tailscale
IP, never the Wi-Fi/LAN the server sits on (the one exception, `share.lab`'s public
links, goes through Tailscale Funnel, which only lets downloads through).

| address | app |
|---|---|
| `home.lab` | Glance dashboard |
| `stats.lab` | Beszel: CPU, RAM, temps |
| `pdf.lab` | BentoPDF: edit, merge, split, sign PDFs |
| `convert.lab` | Transmute (file converter) |
| `latex.lab` | Overleaf: LaTeX with autocomplete |
| `keep.lab` | Readeck: bookmarks that keep a readable copy of the page |
| `draw.lab` | ExcaliDash: Excalidraw that keeps all your drawings |
| `share.lab` | Gokapi: upload a file, send anyone the link (public via Tailscale Funnel) |
| `term.lab` | terminal on the server |

Also running, with no page of its own: a **Tor Snowflake proxy** (`stacks/snowflake`)
that helps people in censored countries reach Tor.

## Rebooting fast

`sudo kexec-reboot` skips the firmware and boots straight into the installed kernel
(so it picks up a kernel update). It's `system/kexec-reboot`, which install.sh puts in
`/usr/local/bin` on Arch.

Or restart everything but the kernel: `sudo systemctl soft-reboot`. If the server
doesn't come back on Tailscale after a kexec (Wi-Fi sometimes doesn't), do a normal
`sudo reboot` at the machine.

## What's where

```
install.sh       sets up a server from scratch
.env             settings (made by install.sh, not in git)
stacks/          one folder per app
  dns/           answers *.lab with this server's Tailscale IP
  caddy/         sends pdf.lab to BentoPDF, etc. (edit Caddyfile)
  glance/        the dashboard (edit config/glance.yml)
  ...
system/          server settings files that install.sh copies into /etc
```

App data lives in `stacks/*/data/`. To move to a new server, copy that folder and
`.env` along with the repo, then run `install.sh`.

## Adding an app

1. Make `stacks/<name>/compose.yaml`. Copy any existing one, give it a
   `container_name`, put it on the `proxy` network, and don't publish ports.
2. Add it to `stacks/caddy/Caddyfile`:
   ```
   http://<name>.{$LAB_DOMAIN} {
   	reverse_proxy <container_name>:<port the app listens on>
   }
   ```
3. Add a tile to `stacks/glance/config/glance.yml`.
4. Run `sudo ./install.sh` again.
