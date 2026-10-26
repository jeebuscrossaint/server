#!/bin/sh
# install.sh: turn a fresh Arch or Alpine machine into the homelab.
#   sudo ./install.sh          install everything and start every app
#   sudo ./install.sh --pull   same, but download newer app versions first
# Safe to run again any time. It only does what's missing.
set -eu
# keep going if the terminal running this dies (e.g. term.lab while Docker restarts)
trap '' HUP

HOMELAB_DIR=$(cd "$(dirname "$0")" && pwd)
ENV_FILE="$HOMELAB_DIR/.env"
PULL=no
RECREATE=no

for arg in "$@"; do
	case $arg in
		--pull) PULL=yes ;;
		-h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown option: $arg (try --help)"; exit 2 ;;
	esac
done

step() { printf '\n:: %s\n' "$*"; }
ok()   { printf ' ✓ %s\n' "$*"; }
die()  { printf ' ✗ %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run it as root: sudo ./install.sh (or doas ./install.sh)"
. /etc/os-release
case $ID in
	arch|alpine) ;;
	*) die "only Arch and Alpine for now (this is $ID)" ;;
esac
# the person who ran sudo/doas, so they can use docker without sudo
ME=${SUDO_USER:-${DOAS_USER:-}}

step "packages"
if [ "$ID" = arch ]; then
	missing=""
	for p in docker docker-compose tailscale git openssl openssh zram-generator kexec-tools binutils; do
		pacman -Q "$p" >/dev/null 2>&1 || missing="$missing $p"
	done
	# shellcheck disable=SC2086
	[ -z "$missing" ] || pacman -Syu --needed --noconfirm $missing
else
	# tailscale lives in Alpine's community repo, which is off by default
	sed -i 's|^#\(.*/community\)$|\1|' /etc/apk/repositories
	apk add --quiet docker docker-cli-compose tailscale git openssl openssh kexec-tools
fi
ok "docker, tailscale, git, kexec-tools"

step "services"
if [ "$ID" = arch ]; then
	systemctl enable --now docker.service tailscaled.service sshd.service >/dev/null 2>&1
else
	for s in docker tailscale sshd; do
		rc-update add "$s" default >/dev/null 2>&1 || true
		rc-service "$s" status >/dev/null 2>&1 || rc-service "$s" start
	done
fi
i=0
until docker info >/dev/null 2>&1; do
	i=$((i + 1)); [ $i -le 30 ] || die "docker didn't start"; sleep 1
done
if [ -n "$ME" ]; then
	if [ "$ID" = arch ]; then usermod -aG docker "$ME"; else addgroup "$ME" docker 2>/dev/null || true; fi
fi
ok "docker, tailscale and ssh start on boot"

step "tailscale"
i=0
until tailscale status --json >/dev/null 2>&1; do
	i=$((i + 1)); [ $i -le 30 ] || die "tailscaled isn't answering"; sleep 1
done
if ! tailscale status --json | grep -q '"BackendState": *"Running"'; then
	echo "   open the link below to add this machine to your Tailscale"
	tailscale up
fi
TS_IP=$(tailscale ip -4 | head -n 1)
ok "on Tailscale as $TS_IP"

step "settings (.env)"
[ -f "$ENV_FILE" ] || cp "$HOMELAB_DIR/.env.example" "$ENV_FILE"
set_env() {
	if grep -q "^$1=" "$ENV_FILE"; then
		sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
	else
		printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
	fi
}
grep -q '^LAB_DOMAIN=.' "$ENV_FILE" || set_env LAB_DOMAIN lab
set_env TAILSCALE_IP "$TS_IP"
set_env HOMELAB_DIR "$HOMELAB_DIR"
# this machine's public Tailscale Funnel address, e.g. server.tail1234.ts.net
TS_NAME=$(tailscale status --peers=false | awk 'NR == 1 { print $2 }')
TS_SUFFIX=$(tailscale status --json | sed -n 's/.*"MagicDNSSuffix": *"\([^"]*\)".*/\1/p' | head -n 1)
[ -z "$TS_SUFFIX" ] || set_env PUBLIC_DOMAIN "$TS_NAME.$TS_SUFFIX"
[ -z "$ME" ] || set_env SERVER_USER "$ME"
# any setting still set to change-me is a secret: give it a random value
for key in $(sed -n 's/^\([A-Z_]*\)=change-me$/\1/p' "$ENV_FILE"); do
	set_env "$key" "$(openssl rand -hex 32)"
done
# settings added to .env.example after .env was made
for key in $(sed -n 's/^\([A-Z_]*\)=.*/\1/p' "$HOMELAB_DIR/.env.example"); do
	grep -q "^$key=" "$ENV_FILE" && continue
	val=$(sed -n "s/^$key=//p" "$HOMELAB_DIR/.env.example")
	[ "$val" = change-me ] && val=$(openssl rand -hex 32)
	set_env "$key" "$val"
done
chown "$(stat -c %u:%g "$HOMELAB_DIR")" "$ENV_FILE"
LAB=$(sed -n 's/^LAB_DOMAIN=//p' "$ENV_FILE")
ok "apps will be at *.$LAB"

step "server settings"
# Docker: cap each app's logs, and keep apps running while Docker itself restarts
mkdir -p /etc/docker
if ! cmp -s "$HOMELAB_DIR/system/docker-daemon.json" /etc/docker/daemon.json; then
	cp "$HOMELAB_DIR/system/docker-daemon.json" /etc/docker/daemon.json
	if [ "$ID" = arch ]; then systemctl restart docker; else rc-service docker restart; fi
	i=0
	until docker info >/dev/null 2>&1; do
		i=$((i + 1)); [ $i -le 30 ] || die "docker didn't come back"; sleep 1
	done
	RECREATE=yes # the log limits only apply to apps started after this
fi
ok "app logs capped at 30MB each, apps survive docker restarts"
install -D -m 644 "$HOMELAB_DIR/system/sysctl-tailscale-bind.conf" /etc/sysctl.d/99-tailscale-bind.conf
sysctl -q -p /etc/sysctl.d/99-tailscale-bind.conf
ok "apps listen on Tailscale only, even when Docker starts first at boot"
# SSH: no passwords; your devices get in through Tailscale SSH instead
grep -q '^Include /etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config ||
	sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
install -D -m 644 "$HOMELAB_DIR/system/sshd-no-passwords.conf" /etc/ssh/sshd_config.d/10-no-passwords.conf
sshd -t || die "the SSH settings don't check out (sshd -t), not reloading SSH"
if [ "$ID" = arch ]; then systemctl reload sshd; else rc-service sshd reload >/dev/null; fi
tailscale set --ssh
ok "SSH takes keys only; ssh from your devices goes through Tailscale SSH"
if [ "$ID" = arch ]; then
	install -Dm644 "$HOMELAB_DIR/system/zram-generator.conf" /etc/systemd/zram-generator.conf
	install -Dm644 "$HOMELAB_DIR/system/sysctl-zram.conf" /etc/sysctl.d/99-zram.conf
	sysctl -q --load=/etc/sysctl.d/99-zram.conf
	systemctl daemon-reload
	systemctl start systemd-zram-setup@zram0.service >/dev/null 2>&1 || true
	ok "compressed swap in RAM (zram), tuned"
	install -Dm644 "$HOMELAB_DIR/system/docker-prune.service" /etc/systemd/system/docker-prune.service
	install -Dm644 "$HOMELAB_DIR/system/docker-prune.timer" /etc/systemd/system/docker-prune.timer
	systemctl daemon-reload
	systemctl enable --now docker-prune.timer >/dev/null 2>&1
	ok "old app versions get cleaned up weekly"
	install -Dm644 "$HOMELAB_DIR/system/logind-server.conf" /etc/systemd/logind.conf.d/server.conf
	systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1
	systemctl set-default multi-user.target >/dev/null 2>&1
	install -Dm644 "$HOMELAB_DIR/system/screen-off.service" /etc/systemd/system/screen-off.service
	systemctl daemon-reload
	systemctl enable screen-off.service >/dev/null 2>&1
	ok "lid closed keeps running, never sleeps, boots to text, screen turns off when idle"
	install -Dm755 "$HOMELAB_DIR/system/kexec-reboot" /usr/local/bin/kexec-reboot
	ok "sudo kexec-reboot restarts without going through the firmware"
else
	install -D -m 755 "$HOMELAB_DIR/system/screen-off.start" /etc/local.d/screen-off.start
	install -D -m 755 "$HOMELAB_DIR/system/docker-prune.periodic" /etc/periodic/weekly/docker-prune
	rc-update add local default >/dev/null 2>&1 || true
	ok "screen turns off when idle"
fi

step "apps"
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy >/dev/null
# downloads fail a lot on flaky wifi (Docker Hub especially), so each app gets 8 tries
up() {
	name=$(basename "$1")
	for try in 1 2 3 4 5 6 7 8; do
		if (
			cd "$1"
			if [ "$PULL" = yes ]; then docker compose pull --quiet; fi
			if [ "$RECREATE" = yes ]; then set -- --force-recreate; else set --; fi
			docker compose up -d --build --quiet-pull --remove-orphans "$@" >/dev/null 2>&1
		); then
			ok "$name"; return 0
		fi
		echo "   $name failed (try $try of 8), retrying..."; sleep 10
	done
	echo " ✗ $name didn't start. See why with: cd $1 && docker compose up"
}
up "$HOMELAB_DIR/dockge"
up "$HOMELAB_DIR/stacks/dns"
up "$HOMELAB_DIR/stacks/caddy"
for dir in "$HOMELAB_DIR"/stacks/*/; do
	dir=${dir%/}
	case $(basename "$dir") in dns|caddy) continue ;; esac
	if [ -f "$dir/compose.yaml" ]; then up "$dir"; fi
done

# term.lab logs in with its own SSH key, so there's no password prompt.
# The key only works from Docker's network (from=), not from anywhere else.
TERM_KEY="$HOMELAB_DIR/stacks/terminal/data/id_ed25519"
if [ -n "$ME" ] && [ -d "$HOMELAB_DIR/stacks/terminal" ]; then
	mkdir -p "$(dirname "$TERM_KEY")"
	[ -f "$TERM_KEY" ] || ssh-keygen -q -t ed25519 -N "" -C homelab-terminal -f "$TERM_KEY"
	HOME_DIR=$(getent passwd "$ME" | cut -d: -f6)
	AUTH="$HOME_DIR/.ssh/authorized_keys"
	mkdir -p "$HOME_DIR/.ssh"
	if ! grep -q homelab-terminal "$AUTH" 2>/dev/null; then
		printf 'from="172.16.0.0/12" %s\n' "$(cat "$TERM_KEY.pub")" >> "$AUTH"
	fi
	chown -R "$ME:" "$HOME_DIR/.ssh"
	chmod 700 "$HOME_DIR/.ssh"
	chmod 600 "$AUTH"
	# where coat drops term.lab's colors (over ssh, as you, so it must be yours)
	mkdir -p "$HOMELAB_DIR/stacks/terminal/theme"
	chown "$ME:" "$HOMELAB_DIR/stacks/terminal/theme"
	ok "term.lab logs you in without a password"
fi

# Beszel's agent needs the hub's public key, which the hub only makes on its first start
BESZEL="$HOMELAB_DIR/stacks/beszel"
if [ -d "$BESZEL" ] && ! grep -q '^BESZEL_KEY=.' "$ENV_FILE"; then
	i=0
	while [ ! -f "$BESZEL/data/hub/id_ed25519" ] && [ $i -lt 30 ]; do i=$((i + 1)); sleep 1; done
	if [ -f "$BESZEL/data/hub/id_ed25519" ]; then
		set_env BESZEL_KEY "$(ssh-keygen -y -f "$BESZEL/data/hub/id_ed25519")"
		up "$BESZEL"
	fi
fi

# Overleaf: one admin user that latex.lab signs you in as (Caddy serves the sign-in page)
OVERLEAF="$HOMELAB_DIR/stacks/overleaf"
if [ -d "$OVERLEAF" ]; then
	i=0
	until docker exec overleaf curl -fs http://localhost/status >/dev/null 2>&1; do
		i=$((i + 1)); [ $i -le 60 ] || break; sleep 2
	done
	if docker exec -i -w /overleaf/services/web \
		-e OVERLEAF_EMAIL="me@$LAB.local" \
		-e OVERLEAF_PASSWORD="$(sed -n 's/^OVERLEAF_PASSWORD=//p' "$ENV_FILE")" \
		overleaf node --input-type=module < "$OVERLEAF/make-user.mjs" >/dev/null 2>&1; then
		ok "latex.lab signs you in without a password"
	else
		echo " ✗ couldn't make the Overleaf user. See why with:"
		echo "   docker exec -i -w /overleaf/services/web overleaf node --input-type=module < $OVERLEAF/make-user.mjs"
	fi
fi

# Dockge: one user, then its login screen turned off
if docker exec -i -w /app -e DOCKGE_PASSWORD="$(sed -n 's/^DOCKGE_PASSWORD=//p' "$ENV_FILE")" \
	dockge node - < "$HOMELAB_DIR/dockge/setup.js" >/dev/null 2>&1; then
	ok "dockge.lab has no login screen"
else
	echo " ✗ couldn't set up Dockge's user. See why with:"
	echo "   docker exec -i -w /app dockge node - < $HOMELAB_DIR/dockge/setup.js"
fi

# Transmute: one user that convert.lab signs you in as (Caddy serves the sign-in page)
TRANSMUTE="$HOMELAB_DIR/stacks/transmute"
if [ -d "$TRANSMUTE" ]; then
	i=0
	until docker exec transmute python3 -c 'import urllib.request as u; u.urlopen("http://localhost:3313/api/users/bootstrap-status")' >/dev/null 2>&1; do
		i=$((i + 1)); [ $i -le 30 ] || break; sleep 2
	done
	if docker exec -i -e TRANSMUTE_PASSWORD="$(sed -n 's/^TRANSMUTE_PASSWORD=//p' "$ENV_FILE")" \
		transmute python3 - < "$TRANSMUTE/make-user.py" >/dev/null 2>&1; then
		ok "convert.lab signs you in without a password"
	else
		echo " ✗ couldn't make the Transmute user. See why with:"
		echo "   docker exec -i transmute python3 - < $TRANSMUTE/make-user.py"
	fi
fi

# Readeck: one user that keep.lab signs you in as (Caddy serves the sign-in page)
if [ -d "$HOMELAB_DIR/stacks/readeck" ]; then
	i=0
	until docker exec readeck /bin/readeck healthcheck -config config.toml >/dev/null 2>&1; do
		i=$((i + 1)); [ $i -le 30 ] || break; sleep 2
	done
	if out=$(docker exec -e READECK_PASSWORD="$(sed -n 's/^READECK_PASSWORD=//p' "$ENV_FILE")" readeck \
		/bin/readeck user -config config.toml -u lab -email "lab@$LAB.local" -p env:READECK_PASSWORD 2>&1); then
		# Readeck only notices its first user on start, until then it shows its setup page
		case "$out" in *created*) docker restart readeck >/dev/null ;; esac
		ok "keep.lab signs you in without a password"
	else
		echo " ✗ couldn't make the Readeck user: $out"
	fi
fi

# Gokapi: fill in its first-start setup page (Caddy signs you in on share.lab)
GOKAPI="$HOMELAB_DIR/stacks/gokapi"
if [ -d "$GOKAPI" ] && ! docker exec gokapi test -f /app/config/config.json 2>/dev/null; then
	i=0
	until docker exec gokapi curl -fs -o /dev/null http://127.0.0.1:53842/setup/ 2>/dev/null; do
		i=$((i + 1)); [ $i -le 30 ] || break; sleep 2
	done
	if docker exec -i -e PUBLIC_DOMAIN="$(sed -n 's/^PUBLIC_DOMAIN=//p' "$ENV_FILE")" \
		gokapi sh -s < "$GOKAPI/setup.sh" >/dev/null 2>&1; then
		ok "share.lab is set up"
	else
		echo " ✗ couldn't set up Gokapi. See why with:"
		echo "   docker exec -i -e PUBLIC_DOMAIN=... gokapi sh -s < $GOKAPI/setup.sh"
	fi
fi

# ntfy: one user your phone's ntfy app signs in as, and a token Caddy signs ntfy.lab in with
if [ -d "$HOMELAB_DIR/stacks/ntfy" ]; then
	i=0
	until docker exec ntfy wget -q -O /dev/null http://localhost/v1/health 2>/dev/null; do
		i=$((i + 1)); [ $i -le 30 ] || break; sleep 2
	done
	docker exec ntfy ntfy user list 2>&1 | grep -q '^user lab ' ||
		docker exec -e NTFY_PASSWORD="$(sed -n 's/^NTFY_PASSWORD=//p' "$ENV_FILE")" ntfy \
			ntfy user add --role=admin lab >/dev/null 2>&1 || true
	if ! grep -q '^NTFY_TOKEN=tk_' "$ENV_FILE"; then
		token=$(docker exec ntfy ntfy token add --label=caddy lab 2>&1 | grep -o 'tk_[a-z0-9]*' || true)
		if [ -n "$token" ]; then
			set_env NTFY_TOKEN "$token"
			up "$HOMELAB_DIR/stacks/caddy" # it reads the token on start
		fi
	fi
	if grep -q '^NTFY_TOKEN=tk_' "$ENV_FILE"; then
		ok "ntfy.lab signs you in without a password"
	else
		echo " ✗ couldn't make the ntfy user. See why with:"
		echo "   docker exec -e NTFY_PASSWORD=... ntfy ntfy user add --role=admin lab"
	fi
fi

step "done"
cat <<MSG
   Dashboard: https://home.$LAB
   On each device, trust the certificate once: open http://ca.$LAB (see README)

   If this is a new server (or its Tailscale IP changed), point .$LAB at it once:
   Tailscale admin > DNS > Add nameserver > Custom > $TS_IP
   then turn on "Restrict to domain" and type: $LAB

   To make share.lab's links work for people outside your Tailscale, run once:
   sudo tailscale funnel --bg --https=8443 3001
   and so your phone's ntfy app can reach ntfy, also:
   sudo tailscale funnel --bg --https=10000 3002
   (not plain --bg 3001: that takes port 443 and breaks every .$LAB site)
MSG
