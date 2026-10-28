#!/bin/sh
# Turns i2pd's web console into /www/stats.json for the dashboard tile.
# i2pd's transit byte count resets when it restarts, so keep an all-time total in /data/state:
#   <base transit bytes> <last transit bytes>
S=/data/state
[ -f "$S" ] || echo "0 0" > "$S"
mkdir -p /www
busybox httpd -p "$LISTEN" -h /www
while true; do
	p=$(wget -qO- http://localhost:7070/ 2>/dev/null | tr -d '\r' | sed 's/<br[^>]*>/\n/g; s/<[^>]*>//g')
	if [ -n "$p" ]; then
		# "Transit: 1.23 MiB (0.50 KiB/s)"
		t=$(echo "$p" | awk '$1 == "Transit:" {
			m = 1
			if ($3 == "KiB") m = 1024; else if ($3 == "MiB") m = 1048576
			else if ($3 == "GiB") m = 1073741824; else if ($3 == "TiB") m = 1099511627776
			printf "%.0f", $2 * m; exit }')
		[ -n "$t" ] || t=0
		# "Client Tunnels: 10 Transit Tunnels: 25"
		n=$(echo "$p" | grep -o 'Transit Tunnels: [0-9]*' | grep -o '[0-9]*$' | head -n1)
		st=$(echo "$p" | sed -n 's/^ *Network status: *//p' | head -n1 | sed 's/ *$//; s/"//g')
		read -r bt lt < "$S"
		# smaller than last time means i2pd restarted: bank the old total
		if [ "$t" -lt "$lt" ]; then bt=$((bt + lt)); fi
		# write then rename, so a power cut mid-write can't wipe the totals
		echo "$bt $t" > "$S.tmp" && mv "$S.tmp" "$S"
		printf '{"tunnels":%s,"transit_mb":%s,"status":"%s"}\n' \
			"${n:-0}" $(((bt + t) / 1048576)) "${st:--}" > /www/stats.json.tmp
		mv /www/stats.json.tmp /www/stats.json
	fi
	sleep 60
done
