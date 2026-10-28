#!/bin/sh
# Starts ttyd for term.lab in coat's colors and font, from /theme/colors.json
# (coat's colors module copies it here: `colors: send: [me@server:<this dir>]`).
# Without it, plain VGA colors. When the file changes, ttyd restarts with the new
# scheme, so a reload of the page picks it up.
f=/theme/colors.json

vga='{"background":"#000000","foreground":"#aaaaaa","cursor":"#aaaaaa","black":"#000000","red":"#aa0000","green":"#00aa00","yellow":"#aa5500","blue":"#0000aa","magenta":"#aa00aa","cyan":"#00aaaa","white":"#aaaaaa","brightBlack":"#555555","brightRed":"#ff5555","brightGreen":"#55ff55","brightYellow":"#ffff55","brightBlue":"#5555ff","brightMagenta":"#ff55ff","brightCyan":"#55ffff","brightWhite":"#ffffff"}'

# the same slots coat's kitty module uses, so both terminals match
theme() {
	jq -ce '.colors | {
		background: .base00, foreground: .base05, cursor: .base05, cursorAccent: .base00,
		selectionBackground: .base02, selectionForeground: .base05,
		black: .base00, red: .base08, green: .base0B, yellow: .base0A,
		blue: .base0D, magenta: .base0E, cyan: .base0C, white: .base05,
		brightBlack: .base03, brightRed: .base08, brightGreen: .base0B, brightYellow: .base0A,
		brightBlue: .base0D, brightMagenta: .base0E, brightCyan: .base0C, brightWhite: .base07
	}' "$f" 2>/dev/null || echo "$vga"
}
font() {
	name=$(jq -r '.font.monospace // empty' "$f" 2>/dev/null)
	echo "${name:+$name, }monospace"
}

trap 'kill $pid 2>/dev/null; exit 0' TERM INT
while :; do
	sum=$(cksum "$f" 2>/dev/null)
	ttyd --writable -t titleFixed=server -t fontSize=16 -t cursorStyle=block \
		-t "fontFamily=$(font)" -t "theme=$(theme)" \
		ssh -i /data/id_ed25519 -o UserKnownHostsFile=/data/known_hosts -o StrictHostKeyChecking=accept-new \
		"$SERVER_USER@host.docker.internal" &
	pid=$!
	while kill -0 $pid 2>/dev/null && [ "$(cksum "$f" 2>/dev/null)" = "$sum" ]; do sleep 2; done
	kill $pid 2>/dev/null
	wait $pid
	sleep 1 # if ttyd keeps failing to start, don't spin the CPU
done
