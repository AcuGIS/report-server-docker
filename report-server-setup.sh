#!/usr/bin/env bash
# Interactive Compose setup. Writes .env in this directory before the stack starts.
# Does not start PostgreSQL, Report Server, or Designer Web.
# Does not install a Report Server license or a Designer Web license.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ROOT}/.env"
UMASK_SET=077

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

stop_early() {
  printf '\n' >&2
  die "Setup stopped before it finished. Existing configuration was left unchanged."
}

prompt_line() {
  local text="$1"
  local default="${2:-}"
  local reply=""
  if [[ -n "$default" ]]; then
    if ! IFS= read -r -p "${text} [${default}]: " reply; then
      stop_early
    fi
    if [[ -z "$reply" ]]; then
      reply="$default"
    fi
  else
    if ! IFS= read -r -p "${text}" reply; then
      stop_early
    fi
  fi
  PROMPT_REPLY="$reply"
}

prompt_secret() {
  local reply=""
  if ! IFS= read -rs -p "$1" reply; then
    stop_early
  fi
  printf '\n' >&2
  PROMPT_SECRET="$reply"
}

confirm_no() {
  local reply=""
  if ! IFS= read -r -p "$1 [y/N]: " reply; then
    stop_early
  fi
  case "$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

generate_db_pass() {
  local pass=""
  if command -v php >/dev/null 2>&1; then
    pass="$(php -r 'echo bin2hex(random_bytes(24));' 2>/dev/null || true)"
  fi
  if [[ ${#pass} -ne 48 ]]; then
    command -v od >/dev/null 2>&1 || die "Could not generate the internal PostgreSQL password."
    pass="$(od -An -tx1 -N 24 /dev/urandom | tr -d ' \n')"
  fi
  [[ ${#pass} -eq 48 && "$pass" =~ ^[0-9a-f]{48}$ ]] || die "Could not generate the internal PostgreSQL password."
  printf '%s' "$pass"
}

generate_internal_token() {
  local token=""
  if command -v php >/dev/null 2>&1; then
    token="$(php -r 'echo bin2hex(random_bytes(32));' 2>/dev/null || true)"
  fi
  if [[ ${#token} -ne 64 ]]; then
    command -v od >/dev/null 2>&1 || die "Could not generate the Designer internal token."
    token="$(od -An -tx1 -N 32 /dev/urandom | tr -d ' \n')"
  fi
  [[ ${#token} -eq 64 && "$token" =~ ^[0-9a-f]{64}$ ]] || die "Could not generate the Designer internal token."
  printf '%s' "$token"
}

validate_tz() {
  local tz="$1" root
  [[ -n "$tz" ]] || return 1
  [[ "$tz" != *$'\n'* && "$tz" != *$'\r'* ]] || return 1
  [[ "$tz" != *..* && "$tz" != /* && "$tz" != *\\* ]] || return 1
  # Image tzdata lives here. JRS_ZONEINFO_DIR is only for tests.
  root="${JRS_ZONEINFO_DIR:-/usr/share/zoneinfo}"
  [[ -f "${root}/${tz}" ]]
}

# Compose dotenv: unquoted safe tokens, single quotes when possible,
# double quotes with $$ for a literal $ when a single quote is present.
quote_env() {
  local v="$1"
  if [[ "$v" =~ ^[A-Za-z0-9_./:@+:-]+$ ]]; then
    printf '%s' "$v"
    return
  fi
  if [[ "$v" != *"'"* ]]; then
    printf "'%s'" "$v"
    return
  fi
  local out='"' i c
  for ((i = 0; i < ${#v}; i++)); do
    c="${v:i:1}"
    case "$c" in
      \\) out+='\\' ;;
      \") out+='\"' ;;
      \$) out+='$$' ;;
      *) out+="$c" ;;
    esac
  done
  out+='"'
  printf '%s' "$out"
}

unescape_env() {
  local val="$1"
  val="${val%$'\r'}"
  if [[ ${#val} -ge 2 && "${val:0:1}" == "'" && "${val: -1}" == "'" ]]; then
    printf '%s' "${val:1:${#val}-2}"
    return
  fi
  if [[ ${#val} -ge 2 && "${val:0:1}" == '"' && "${val: -1}" == '"' ]]; then
    val="${val:1:${#val}-2}"
    local out="" i c
    for ((i = 0; i < ${#val}; i++)); do
      c="${val:i:1}"
      if [[ "$c" == '\' && $((i + 1)) -lt ${#val} ]]; then
        local n="${val:$((i + 1)):1}"
        case "$n" in
          \\|\"|\$) out+="$n"; i=$((i + 1)); continue ;;
        esac
      fi
      if [[ "$c" == '$' && $((i + 1)) -lt ${#val} && "${val:$((i + 1)):1}" == '$' ]]; then
        out+='$'
        i=$((i + 1))
        continue
      fi
      out+="$c"
    done
    printf '%s' "$out"
    return
  fi
  printf '%s' "$(trim "$val")"
}

env_value() {
  local key="$1" line val
  [[ -f "$ENV_FILE" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?${key}=(.*)$ ]]; then
      unescape_env "${BASH_REMATCH[2]}"
      return 0
    fi
  done < "$ENV_FILE"
  return 1
}

placeholder_db() {
  local v="${1:-}"
  [[ -z "$v" || "$v" == "change-me-strong-password" ]]
}

placeholder_admin() {
  local v="${1:-}"
  [[ -z "$v" || "$v" == "change-me-admin-password" ]]
}

set_key() {
  local key="$1" value="$2"
  local tmp="${ENV_FILE}.tmp.$$"
  local line found=0
  : >"$tmp"
  if [[ -f "$ENV_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?${key}= ]]; then
        if [[ "$found" -eq 0 ]]; then
          printf '%s=%s\n' "$key" "$(quote_env "$value")" >>"$tmp"
          found=1
        fi
      else
        printf '%s\n' "$line" >>"$tmp"
      fi
    done < "$ENV_FILE"
  fi
  if [[ "$found" -eq 0 ]]; then
    printf '%s=%s\n' "$key" "$(quote_env "$value")" >>"$tmp"
  fi
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
}

write_new_env() {
  local db_pass="$1" token="$2" admin_user="$3" admin_pass="$4" tz="$5" image="$6" designer_image="$7"
  local tmp="${ENV_FILE}.tmp.$$"
  umask "$UMASK_SET"
  {
    printf '%s\n' '# AcuGIS Report Server 1.0.22'
    printf '%s\n' '# Created by: docker compose run --rm -it report-server-setup'
    printf '%s\n' '# The internal PostgreSQL password and Designer internal token were generated. Do not commit this file.'
    printf '%s\n' '# Advanced settings can be edited here. Then run: docker compose up -d'
    printf '\n'
    printf 'JRS_DB_PASS=%s\n' "$(quote_env "$db_pass")"
    printf 'JRS_DESIGNER_INTERNAL_TOKEN=%s\n' "$(quote_env "$token")"
    printf 'JRS_ADMIN_USER=%s\n' "$(quote_env "$admin_user")"
    printf 'JRS_ADMIN_PASSWORD=%s\n' "$(quote_env "$admin_pass")"
    printf 'JRS_HOST_PORT=%s\n' '9088'
    printf 'JRS_DB_NAME=%s\n' 'jasper_reports'
    printf 'JRS_DB_USER=%s\n' 'jasper'
    printf 'JRS_DB_SCHEMA=%s\n' 'public'
    printf 'JRS_DB_SSLMODE=%s\n' 'disable'
    printf 'JRS_DATA_HOST_PATH=%s\n' './data'
    printf 'ACUGIS_DOCKER_SEED_DEMO=%s\n' '1'
    printf 'TZ=%s\n' "$(quote_env "$tz")"
    if [[ -n "$image" ]]; then
      printf 'REPORT_SERVER_IMAGE=%s\n' "$(quote_env "$image")"
    fi
    if [[ -n "$designer_image" ]]; then
      printf 'REPORT_DESIGNER_IMAGE=%s\n' "$(quote_env "$designer_image")"
    fi
    printf '\n'
    printf '%s\n' '# Optional settings. Uncomment when needed.'
    printf '%s\n' '# JRS_ENVIRONMENT=production'
    printf '%s\n' '# JRS_SMTP_HOST='
    printf '%s\n' '# JRS_SMTP_PORT=587'
    printf '%s\n' '# JRS_SMTP_USER='
    printf '%s\n' '# JRS_SMTP_PASS='
    printf '%s\n' '# JRS_SMTP_FROM=reports@example.com'
    printf '%s\n' '# JRS_SCHEDULER_POLL_INTERVAL=15s'
    printf '%s\n' '# JRS_DB_HOST=postgres'
    printf '%s\n' '# JRS_DB_PORT=5432'
    printf '%s\n' '# JRS_QGIS_UPSTREAM=http://qgis-server'
    printf '%s\n' '# JRS_QGIS_MAP_PREFIX=/qgis/projects'
  } >"$tmp"
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
}

collect_admin_user() {
  local default="$1" user
  while true; do
    prompt_line "Administrator username" "$default"
    user="$(trim "$PROMPT_REPLY")"
    if [[ -z "$user" ]]; then
      user="$default"
    fi
    if [[ "$user" == *$'\n'* || "$user" == *$'\r'* || "$user" == *"'"* ]]; then
      printf '%s\n' "Enter a username without quotes or line breaks." >&2
      continue
    fi
    PROMPT_REPLY="$user"
    return 0
  done
}

collect_admin_password() {
  local pass confirm
  while true; do
    prompt_secret "Administrator password: "
    pass="$PROMPT_SECRET"
    if [[ -z "$pass" ]]; then
      printf '%s\n' "Password cannot be blank." >&2
      continue
    fi
    if [[ "$pass" == "change-me-admin-password" ]]; then
      printf '%s\n' "That password is refused by Report Server. Choose a different password." >&2
      continue
    fi
    if [[ "$pass" == *$'\n'* || "$pass" == *$'\r'* ]]; then
      printf '%s\n' "Password cannot contain a line break." >&2
      continue
    fi
    prompt_secret "Confirm administrator password: "
    confirm="$PROMPT_SECRET"
    if [[ "$pass" != "$confirm" ]]; then
      printf '%s\n' "Passwords do not match." >&2
      continue
    fi
    PROMPT_SECRET="$pass"
    return 0
  done
}

collect_timezone() {
  local default="$1" tz
  while true; do
    prompt_line "Timezone" "$default"
    tz="$(trim "$PROMPT_REPLY")"
    if [[ -z "$tz" ]]; then
      tz="$default"
    fi
    if validate_tz "$tz"; then
      PROMPT_REPLY="$tz"
      return 0
    fi
    printf '%s\n' "Unknown timezone. Use an IANA name such as UTC or America/New_York." >&2
  done
}

say_licensing() {
  if [[ "${ACUGIS_BUILD_EDITION:-}" != "professional" ]]; then
    return 0
  fi
  cat <<'EOF'

Professional licensing

No license is required to start your 30-day trial.
After you sign in, open License to start that trial or install a license.
Setup does not install a license, and it does not change the existing trial.
EOF
}

say_designer() {
  cat <<'EOF'

Report Designer Web

Designer Web is optional and licensed separately from Report Server.
A Report Server license does not enable it.
Setup does not ask for a Designer license and does not create an installation ID.
After you sign in, open Administration, then License, to start the Designer Web trial or activate a license.
EOF
}

main() {
  local existing=0 replace_db=1 replace_token=1 change_admin_pass=1
  local db_pass="" token="" admin_user="admin" admin_pass="" tz="UTC"
  local cur_db="" cur_token="" cur_admin="" cur_user="" cur_tz="" image designer_image

  if [[ ! -t 0 ]]; then
    printf '%s\n' "Setup is reading answers from stdin. For a terminal, run: docker compose run --rm -it report-server-setup" >&2
  fi

  image="${JRS_SETUP_IMAGE:-${REPORT_SERVER_IMAGE:-}}"
  designer_image="${JRS_SETUP_DESIGNER_IMAGE:-${REPORT_DESIGNER_IMAGE:-}}"

  printf '%s\n' "AcuGIS Report Server setup"
  printf '%s\n' "This writes .env for docker compose up -d."
  printf '%s\n' "The internal PostgreSQL password is generated and is not shown."
  printf '%s\n' "The Designer internal token is generated and is not shown."
  printf '\n'

  if [[ -e "$ENV_FILE" && ! -f "$ENV_FILE" ]]; then
    die ".env exists and is not a file."
  fi

  if [[ -f "$ENV_FILE" ]]; then
    existing=1
    printf '%s\n' "An existing .env was found."
    printf '%s\n' "Continuing can change the administrator and timezone."
    printf '%s\n' "The internal PostgreSQL password is kept unless you explicitly replace it."
    printf '%s\n' "The Designer internal token is kept unless you explicitly replace it."
    printf '\n'
    if ! confirm_no "Continue"; then
      printf '%s\n' "Left the existing configuration unchanged."
      exit 0
    fi
    cur_db="$(env_value JRS_DB_PASS || true)"
    cur_token="$(env_value JRS_DESIGNER_INTERNAL_TOKEN || true)"
    cur_admin="$(env_value JRS_ADMIN_PASSWORD || true)"
    cur_user="$(env_value JRS_ADMIN_USER || true)"
    cur_tz="$(env_value TZ || true)"
    [[ -n "$cur_user" ]] || cur_user="admin"
    [[ -n "$cur_tz" ]] || cur_tz="UTC"
    if placeholder_db "$cur_db"; then
      printf '%s\n' "JRS_DB_PASS is missing or still the example value, so Report Server cannot start."
      printf '%s\n' "A new internal PostgreSQL password will be generated."
      replace_db=1
    elif confirm_no "Replace the internal PostgreSQL password?"; then
      printf '%s\n' "Replacing JRS_DB_PASS does not change a PostgreSQL volume that already initialized."
      printf '%s\n' "Report Server will fail to connect until that database password is changed to match."
      if confirm_no "Replace it anyway?"; then
        replace_db=1
      else
        replace_db=0
      fi
    else
      replace_db=0
    fi
    if [[ -z "$cur_token" ]]; then
      printf '%s\n' "The Designer internal token is missing, so Designer Web cannot start."
      printf '%s\n' "A new Designer internal token will be generated."
      replace_token=1
    elif confirm_no "Replace the Designer internal token?"; then
      printf '%s\n' "Replacing the token does not change reports or the database."
      printf '%s\n' "Recreate Report Server and Designer Web after this so both use the new token."
      if confirm_no "Replace it anyway?"; then
        replace_token=1
      else
        replace_token=0
      fi
    else
      replace_token=0
    fi
    if placeholder_admin "$cur_admin"; then
      printf '%s\n' "The administrator password is missing or still the example value."
      change_admin_pass=1
    elif confirm_no "Change administrator password?"; then
      change_admin_pass=1
    else
      change_admin_pass=0
      admin_pass="$cur_admin"
    fi
    admin_user="$cur_user"
    tz="$cur_tz"
  fi

  collect_admin_user "$admin_user"
  admin_user="$PROMPT_REPLY"
  if [[ "$change_admin_pass" -eq 1 ]]; then
    collect_admin_password
    admin_pass="$PROMPT_SECRET"
  fi
  collect_timezone "$tz"
  tz="$PROMPT_REPLY"

  if [[ "$replace_db" -eq 1 ]]; then
    db_pass="$(generate_db_pass)"
  else
    db_pass="$cur_db"
  fi
  if [[ "$replace_token" -eq 1 ]]; then
    token="$(generate_internal_token)"
  else
    token="$cur_token"
  fi

  say_licensing
  say_designer

  if [[ "$existing" -eq 0 ]]; then
    write_new_env "$db_pass" "$token" "$admin_user" "$admin_pass" "$tz" "$image" "$designer_image"
  else
    if [[ "$replace_db" -eq 1 ]]; then
      set_key JRS_DB_PASS "$db_pass"
    fi
    if [[ "$replace_token" -eq 1 ]]; then
      set_key JRS_DESIGNER_INTERNAL_TOKEN "$token"
    fi
    set_key JRS_ADMIN_USER "$admin_user"
    if [[ "$change_admin_pass" -eq 1 ]]; then
      set_key JRS_ADMIN_PASSWORD "$admin_pass"
    fi
    set_key TZ "$tz"
    for pair in \
      "JRS_HOST_PORT:9088" \
      "JRS_DB_NAME:jasper_reports" \
      "JRS_DB_USER:jasper" \
      "JRS_DB_SCHEMA:public" \
      "JRS_DB_SSLMODE:disable" \
      "JRS_DATA_HOST_PATH:./data" \
      "ACUGIS_DOCKER_SEED_DEMO:1"; do
      local_key="${pair%%:*}"
      local_val="${pair#*:}"
      if ! env_value "$local_key" >/dev/null; then
        set_key "$local_key" "$local_val"
      fi
    done
    if [[ -n "$image" ]] && ! env_value REPORT_SERVER_IMAGE >/dev/null; then
      set_key REPORT_SERVER_IMAGE "$image"
    fi
    if [[ -n "$designer_image" ]] && ! env_value REPORT_DESIGNER_IMAGE >/dev/null; then
      set_key REPORT_DESIGNER_IMAGE "$designer_image"
    fi
  fi
  unset PROMPT_SECRET admin_pass db_pass token

  printf '\n'
  printf '%s\n' "Wrote .env"
  if [[ "$replace_db" -eq 1 ]]; then
    printf '%s\n' "Internal PostgreSQL password: generated and stored in .env"
  else
    printf '%s\n' "Internal PostgreSQL password: kept"
  fi
  if [[ "$replace_token" -eq 1 ]]; then
    printf '%s\n' "Designer internal token: generated and stored in .env"
  else
    printf '%s\n' "Designer internal token: kept"
  fi
  printf '%s\n' "Administrator: ${admin_user}"
  printf '%s\n' "Timezone: ${tz}"
  printf '\n'
  printf '%s\n' "Next:"
  printf '%s\n' "  docker compose up -d"
  printf '%s\n' "Open: http://localhost:9088/"
}

main "$@"
