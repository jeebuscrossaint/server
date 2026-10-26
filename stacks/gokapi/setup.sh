#!/bin/sh
# Fills in Gokapi's first-start setup page. install.sh runs it inside the container
# while there's no config yet:
#   docker exec -i -e PUBLIC_DOMAIN=... gokapi sh -s < setup.sh
# Login is "header": Gokapi signs in whoever Caddy names in Remote-User, and only the
# one user "lab" exists. Links point at the public Funnel address so they work for anyone.
set -e
field() { printf '{"name":"%s","value":"%s"},' "$1" "$2"; }
body=$(
	field dbtype_sel 0
	field sqlite_location ./data/gokapi.sqlite
	for k in redis_location redis_prefix redis_user redis_password; do field $k ""; done
	field redis_ssl_sel 0
	field authentication_sel 2
	field auth_headerkey Remote-User
	field auth_header_admin lab
	field auth_header_only_registered_users 1
	field auth_username ""
	field auth_pw ""
	for k in oauth_provider oauth_id oauth_secret oauth_admin_user oauth_allowed_groups oauth_scope_groups; do field $k ""; done
	field oauth_recheck_interval 12
	field oauth_only_registered_users 0
	field oauth_restrict_groups 0
	field port 53842
	field public_name Share
	field url "https://$PUBLIC_DOMAIN:8443/"
	field url_redirection /admin
	field ssl_sel 0
	field logip_sel 0
	field showfilename_sel 1
	field storage_sel local
	field storage_sel_image local
	field encrypt_sel 0
	field enc_pw ""
)
curl -fsS -H 'Content-Type: application/json' --data "[${body%,}]" http://127.0.0.1:53842/setup/setupResult
