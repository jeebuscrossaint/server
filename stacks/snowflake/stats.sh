#!/bin/sh
# Turns Snowflake's counters into /www/stats.json for the dashboard tile.
# Snowflake's counters reset when it restarts, so keep all-time totals in /data/state:
#   <base conns> <base in> <base out> <last conns> <last in> <last out>
S=/data/state
[ -f "$S" ] || echo "0 0 0 0 0 0" > "$S"
mkdir -p /www
busybox httpd -p "$LISTEN" -h /www
while true; do
	m=$(wget -qO- http://127.0.0.1:9999/internal/metrics 2>/dev/null)
	if [ -n "$m" ]; then
		c=$(echo "$m" | awk '/^tor_snowflake_proxy_connections_total/ { s += $NF } END { printf "%.0f", s }')
		i=$(echo "$m" | awk '/^tor_snowflake_proxy_traffic_inbound_bytes_total/ { s += $NF } END { printf "%.0f", s }')
		o=$(echo "$m" | awk '/^tor_snowflake_proxy_traffic_outbound_bytes_total/ { s += $NF } END { printf "%.0f", s }')
		top=$(echo "$m" | awk -F'"' '/^tor_snowflake_proxy_connections_total\{/ { split($0, a, " "); if (a[2] + 0 > max) { max = a[2] + 0; cc = $2 } } END { print (cc == "" ? "-" : cc) }')
		read -r bc bi bo lc li lo < "$S"
		# smaller than last time means Snowflake restarted: bank the old totals
		if [ "$c" -lt "$lc" ] || [ "$i" -lt "$li" ]; then
			bc=$((bc + lc)); bi=$((bi + li)); bo=$((bo + lo))
		fi
		echo "$bc $bi $bo $c $i $o" > "$S"
		# the traffic counters are in KB (1000 bytes), not bytes. Every relayed byte is
		# counted once coming in and once going out, so count only what went out
		printf '{"helped":%s,"relayed_mb":%s,"top_country":"%s"}\n' \
			$((bc + c)) $(((bo + o) * 1000 / 1048576)) "$top" > /www/stats.json.tmp
		mv /www/stats.json.tmp /www/stats.json
	fi
	sleep 60
done
