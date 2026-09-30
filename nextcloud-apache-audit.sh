#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Apache + Nextcloud security/anomaly triage
# Read-only: this script never modifies Apache or Nextcloud logs.
# -----------------------------------------------------------------------------

# === CONFIGURATION ============================================================
# Usage:
#   ./nextcloud-apache-audit.sh [NEXTCLOUD_LOG_DIR] [APACHE_LOG_DIR]
#
# Positional arguments override environment variables/defaults.
# Examples:
#   ./nextcloud-apache-audit.sh /var/log/nextcloud /var/log/apache2
#   NEXTCLOUD_LOG_DIR=/var/log/nextcloud APACHE_LOG_DIR=/var/log/apache2 ./nextcloud-apache-audit.sh

DEFAULT_NEXTCLOUD_LOG_DIR="/path/to/nextcloud/data"
DEFAULT_APACHE_LOG_DIR="/var/log/apache2"

if (( $# > 2 )); then
    echo "Usage: $0 [NEXTCLOUD_LOG_DIR] [APACHE_LOG_DIR]" >&2
    exit 2
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<EOF
Usage: $0 [NEXTCLOUD_LOG_DIR] [APACHE_LOG_DIR]

Examples:
  $0 /var/log/nextcloud /var/log/apache2
  NEXTCLOUD_LOG_DIR=/var/log/nextcloud APACHE_LOG_DIR=/var/log/apache2 $0

Positional arguments take precedence over environment variables.

Useful environment overrides:
  LOOKBACK_HOURS=24
  REPORT_DIR=/tmp
  NC_MIN_DESKTOP_VERSION=3.1.0
EOF
    exit 0
fi

NEXTCLOUD_LOG_DIR="${1:-${NEXTCLOUD_LOG_DIR:-$DEFAULT_NEXTCLOUD_LOG_DIR}}"
APACHE_LOG_DIR="${2:-${APACHE_LOG_DIR:-$DEFAULT_APACHE_LOG_DIR}}"

# Normalize trailing slashes except for root.
[[ "$NEXTCLOUD_LOG_DIR" != "/" ]] && NEXTCLOUD_LOG_DIR="${NEXTCLOUD_LOG_DIR%/}"
[[ "$APACHE_LOG_DIR" != "/" ]] && APACHE_LOG_DIR="${APACHE_LOG_DIR%/}"

# File discovery patterns. Adjust if your filenames differ.
APACHE_ACCESS_GLOB="${APACHE_ACCESS_GLOB:-*access*log*}"
APACHE_ERROR_GLOB="${APACHE_ERROR_GLOB:-*error*log*}"
NEXTCLOUD_LOG_GLOB="${NEXTCLOUD_LOG_GLOB:-nextcloud*.log*}"

LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
TOP_N="${TOP_N:-25}"
REPORT_DIR="${REPORT_DIR:-/tmp}"

# Thresholds used to call attention to noisy sources.
THRESH_404="${THRESH_404:-30}"
THRESH_AUTH_HTTP="${THRESH_AUTH_HTTP:-20}"
THRESH_5XX="${THRESH_5XX:-20}"
THRESH_NC_AUTH="${THRESH_NC_AUTH:-8}"
THRESH_TOTAL_REQUESTS="${THRESH_TOTAL_REQUESTS:-5000}"

# Minimum Nextcloud desktop client version used for legacy-client warnings.
# Override if your server policy differs, e.g. NC_MIN_DESKTOP_VERSION=3.15.0.
NC_MIN_DESKTOP_VERSION="${NC_MIN_DESKTOP_VERSION:-3.1.0}"
# ============================================================================

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $1" >&2
        exit 1
    }
}

for cmd in awk grep sed sort uniq find date gzip mktemp tee wc head cat paste comm tr; do
    require_cmd "$cmd"
done

if [[ ! "$LOOKBACK_HOURS" =~ ^[0-9]+$ ]] || (( LOOKBACK_HOURS < 1 )); then
    echo "ERROR: LOOKBACK_HOURS must be a positive integer." >&2
    exit 1
fi

if [[ ! -d "$APACHE_LOG_DIR" ]]; then
    echo "ERROR: Apache log directory does not exist: $APACHE_LOG_DIR" >&2
    exit 1
fi

if [[ ! -d "$NEXTCLOUD_LOG_DIR" ]]; then
    echo "ERROR: Nextcloud log directory does not exist: $NEXTCLOUD_LOG_DIR" >&2
    exit 1
fi

mkdir -p "$REPORT_DIR"
# Reports can contain IP addresses, usernames and security events. Keep them private.
umask 077
TMPDIR_AUDIT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_AUDIT"' EXIT

REPORT_FILE="$REPORT_DIR/security-audit-$(date '+%Y%m%d-%H%M%S').txt"

stream_logs() {
    local dir="$1"
    local glob="$2"
    local f

    while IFS= read -r -d '' f; do
        case "$f" in
            *.gz) gzip -cd -- "$f" 2>/dev/null || true ;;
            *)    cat -- "$f" 2>/dev/null || true ;;
        esac
    done < <(find "$dir" -maxdepth 1 -type f -name "$glob" -print0 2>/dev/null | sort -z)
}

join_regex() {
    local IFS='|'
    echo "$*"
}

# Apache access logs normally use: [12/Sep/2026:14:23:11 +0200]
apache_access_hours=()
# Apache error logs commonly use: [Sat Sep 12 14:23:11.123456 2026]
apache_error_hours=()
# Nextcloud timestamps may be server-local or UTC depending on configuration.
nextcloud_hours=()

for ((h=0; h<LOOKBACK_HOURS; h++)); do
    apache_access_hours+=("$(LC_ALL=C date -d "$h hour ago" '+%d/%b/%Y:%H')")
    apache_error_hours+=("$(LC_ALL=C date -d "$h hour ago" '+%b %d %H')")
    nextcloud_hours+=("$(date -d "$h hour ago" '+%Y-%m-%dT%H')")
    nextcloud_hours+=("$(date -u -d "$h hour ago" '+%Y-%m-%dT%H')")
done

APACHE_ACCESS_HOUR_RE="$(join_regex "${apache_access_hours[@]}")"
APACHE_ERROR_HOUR_RE="$(join_regex "${apache_error_hours[@]}")"
# Deduplicate local/UTC hour strings before constructing the regex.
NEXTCLOUD_HOUR_RE="$(printf '%s
' "${nextcloud_hours[@]}" | sort -u | paste -sd '|' -)"

ACCESS_RAW="$TMPDIR_AUDIT/apache-access.log"
ERROR_RAW="$TMPDIR_AUDIT/apache-error.log"
NC_RAW="$TMPDIR_AUDIT/nextcloud.log"
ACCESS_TSV="$TMPDIR_AUDIT/apache-access.tsv"
NC_TSV="$TMPDIR_AUDIT/nextcloud.tsv"

stream_logs "$APACHE_LOG_DIR" "$APACHE_ACCESS_GLOB"     | grep -E "\[($APACHE_ACCESS_HOUR_RE):" > "$ACCESS_RAW" || true

stream_logs "$APACHE_LOG_DIR" "$APACHE_ERROR_GLOB"     | grep -E "($APACHE_ERROR_HOUR_RE):" > "$ERROR_RAW" || true

stream_logs "$NEXTCLOUD_LOG_DIR" "$NEXTCLOUD_LOG_GLOB"     | grep -E "($NEXTCLOUD_HOUR_RE)" > "$NC_RAW" || true

# Convert Apache combined/vhost-combined lines into:
# IP<TAB>METHOD<TAB>URI<TAB>STATUS<TAB>USER_AGENT<TAB>AUTH_USER
awk '
BEGIN { OFS="	" }
{
    # Find client IP in the portion before the timestamp. This handles both
    # standard combined logs and Debian/Ubuntu vhost-combined formats.
    prefix=$0
    sub(/[.*/, "", prefix)
    n=split(prefix, a, /[[:space:]]+/)
    ip="-"
    for (i=n; i>=1; i--) {
        if (a[i] ~ /^[0-9]{1,3}(.[0-9]{1,3}){3}$/ ||
            (a[i] ~ /:/ && a[i] ~ /^[0-9A-Fa-f:]+$/)) {
            ip=a[i]
            break
        }
    }

    qn=split($0, q, /"/)
    if (qn < 3) next

    request=q[2]
    rn=split(request, r, /[[:space:]]+/)
    method=(rn >= 1 ? r[1] : "-")
    uri=(rn >= 2 ? r[2] : "-")

    # In standard/combined logs the authenticated user is the last field
    # before the timestamp (typically "-" when no HTTP auth user exists).
    auth_user="-"
    for (i=n; i>=1; i--) {
        if (a[i] != "") { auth_user=a[i]; break }
    }

    status="-"
    rest=q[3]
    if (match(rest, /[[:space:]][0-9][0-9][0-9][[:space:]]/)) {
        status=substr(rest, RSTART+1, 3)
    }

    ua=(qn >= 6 ? q[6] : "-")
    gsub(/[	
]/, " ", ua)
    gsub(/[	
]/, " ", uri)
    gsub(/[	
]/, " ", auth_user)
    print ip, method, uri, status, ua, auth_user
}
' "$ACCESS_RAW" > "$ACCESS_TSV"

JQ_AVAILABLE=0
if command -v jq >/dev/null 2>&1; then
    JQ_AVAILABLE=1
    jq -Rr '
        fromjson?
        | select(type == "object")
        | [
            (.time // "-"),
            (.remoteAddr // "-"),
            (.user // "-"),
            (.app // "-"),
            ((.level // 0) | tostring),
            ((.message // "") | tostring | gsub("[\t\r\n]"; " "))
          ]
        | @tsv
    ' "$NC_RAW" > "$NC_TSV" 2>/dev/null || true
else
    : > "$NC_TSV"
fi

section() {
    printf '
================================================================================
'
    printf '%s
' "$1"
    printf '================================================================================
'
}

count_lines() {
    wc -l < "$1" | tr -d ' '
}

# Return success when version $1 is lower than version $2.
# Handles numeric dotted versions such as 2.5.1, 3.1, 3.15.2.
version_lt() {
    local a="$1" b="$2"
    awk -v A="$a" -v B="$b" 'BEGIN {
        na=split(A,a,"."); nb=split(B,b,".");
        n=(na>nb?na:nb)
        for (i=1;i<=n;i++) {
            ai=(i<=na ? a[i]+0 : 0)
            bi=(i<=nb ? b[i]+0 : 0)
            if (ai < bi) exit 0
            if (ai > bi) exit 1
        }
        exit 1
    }'
}

# Many report sections intentionally truncate long pipelines with head(1).
# Disable pipefail here so an upstream SIGPIPE caused by head is not treated
# as a fatal script error.
set +o pipefail

{
    echo "Apache + Nextcloud security/anomaly report"
    echo "Generated:          $(date --iso-8601=seconds)"
    echo "Lookback:           ${LOOKBACK_HOURS} hours"
    echo "Apache log dir:     $APACHE_LOG_DIR"
    echo "Nextcloud log dir:  $NEXTCLOUD_LOG_DIR"
    echo "Apache access glob: $APACHE_ACCESS_GLOB"
    echo "Apache error glob:  $APACHE_ERROR_GLOB"
    echo "Apache access files: $(find "$APACHE_LOG_DIR" -maxdepth 1 -type f -name "$APACHE_ACCESS_GLOB" | wc -l | tr -d ' ')"
    echo "Apache error files:  $(find "$APACHE_LOG_DIR" -maxdepth 1 -type f -name "$APACHE_ERROR_GLOB" | wc -l | tr -d ' ')"
    echo "Apache access rows: $(count_lines "$ACCESS_RAW")"
    echo "Apache error rows:  $(count_lines "$ERROR_RAW")"
    echo "Nextcloud rows:     $(count_lines "$NC_RAW")"
    echo "jq available:       $([[ $JQ_AVAILABLE -eq 1 ]] && echo yes || echo no)"
