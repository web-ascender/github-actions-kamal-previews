#!/usr/bin/env bash
# Runner-side database URL parser shared by clone-database and drop-database.
# Source this file then call `kp_parse_db_url <url>`. Sets these vars in the
# caller's scope:
#
#   KP_DB_SCHEME    e.g. "postgres" or "mysql"
#   KP_DB_USER      URL-decoded
#   KP_DB_PASSWORD  URL-decoded
#   KP_DB_HOST
#   KP_DB_PORT      may be empty (caller should default per engine)
#   KP_DB_DBNAME    path component (often unused — clone/drop force maintenance DB)
#   KP_DB_QUERY     raw query string (without leading `?`)
#   KP_DB_SSLMODE   pulled from `?sslmode=…` (postgres convention)
#   KP_DB_SSL_MODE  pulled from `?ssl-mode=…` (mysql convention)
#
# Bash-only — no python/jq dependency. URL-decoding handles the standard
# %XX escapes that surface in real-world URLs (especially passwords).

kp__urldecode() {
  # Convert %XX → \xXX, then ask printf '%b' to interpret the escapes.
  local in="$1"
  # shellcheck disable=SC2059
  printf '%b' "${in//%/\\x}"
}

kp_parse_db_url() {
  local url="$1"
  KP_DB_SCHEME=""
  KP_DB_USER=""
  KP_DB_PASSWORD=""
  KP_DB_HOST=""
  KP_DB_PORT=""
  KP_DB_DBNAME=""
  KP_DB_QUERY=""
  KP_DB_SSLMODE=""
  KP_DB_SSL_MODE=""

  if [[ -z "$url" ]]; then
    echo "kp_parse_db_url: empty url" >&2
    return 1
  fi
  if [[ "$url" != *://* ]]; then
    echo "kp_parse_db_url: missing scheme in $url" >&2
    return 1
  fi

  KP_DB_SCHEME="${url%%://*}"
  local rest="${url#*://}"

  # userinfo@…
  if [[ "$rest" == *@* ]]; then
    local userinfo="${rest%%@*}"
    rest="${rest#*@}"
    if [[ "$userinfo" == *:* ]]; then
      KP_DB_USER="$(kp__urldecode "${userinfo%%:*}")"
      KP_DB_PASSWORD="$(kp__urldecode "${userinfo#*:}")"
    else
      KP_DB_USER="$(kp__urldecode "$userinfo")"
    fi
  fi

  # split off ?query
  if [[ "$rest" == *\?* ]]; then
    KP_DB_QUERY="${rest#*\?}"
    rest="${rest%%\?*}"
  fi

  # split off /dbname
  if [[ "$rest" == */* ]]; then
    KP_DB_DBNAME="${rest#*/}"
    rest="${rest%%/*}"
  fi

  # host[:port]  — bracketed IPv6 not supported (Rails URLs rarely use IPv6).
  if [[ "$rest" == *:* ]]; then
    KP_DB_HOST="${rest%%:*}"
    KP_DB_PORT="${rest#*:}"
  else
    KP_DB_HOST="$rest"
  fi

  # Pull sslmode / ssl-mode out of the query string. Rails / driver naming
  # diverges between postgres (sslmode) and mysql (ssl-mode); we extract
  # both so the caller can pick the right one for its engine.
  if [[ -n "$KP_DB_QUERY" ]]; then
    local p
    IFS='&' read -ra _kp_qs <<< "$KP_DB_QUERY"
    for p in "${_kp_qs[@]}"; do
      case "$p" in
        sslmode=*)   KP_DB_SSLMODE="$(kp__urldecode "${p#sslmode=}")" ;;
        ssl-mode=*)  KP_DB_SSL_MODE="$(kp__urldecode "${p#ssl-mode=}")" ;;
      esac
    done
    unset _kp_qs
  fi

  if [[ -z "$KP_DB_HOST" ]]; then
    echo "kp_parse_db_url: missing host in $url" >&2
    return 1
  fi
}
