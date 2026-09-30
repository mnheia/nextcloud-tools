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
    echo "NC desktop minimum: $NC_MIN_DESKTOP_VERSION"

    section "1. Apache - top client IPs by request count"
    awk -F '\t' '$1 != "-" { c[$1]++ } END { for (ip in c) print c[ip], ip }' "$ACCESS_TSV" \
        | sort -nr | head -n "$TOP_N"

    section "2. Apache - unusually high request volume"
    awk -F '\t' -v t="$THRESH_TOTAL_REQUESTS" '
        $1 != "-" { c[$1]++ }
        END { for (ip in c) if (c[ip] >= t) print c[ip], ip }
    ' "$ACCESS_TSV" | sort -nr

    section "3. Apache - authentication/access failures (401/403)"
    awk -F '\t' -v t="$THRESH_AUTH_HTTP" '
        ($4 == "401" || $4 == "403") && $1 != "-" { c[$1]++ }
        END { for (ip in c) if (c[ip] >= t) print c[ip], ip }
    ' "$ACCESS_TSV" | sort -nr | head -n "$TOP_N"

    section "4. Apache - 404 scanning/noise candidates"
    awk -F '\t' -v t="$THRESH_404" '
        $4 == "404" && $1 != "-" { c[$1]++ }
        END { for (ip in c) if (c[ip] >= t) print c[ip], ip }
    ' "$ACCESS_TSV" | sort -nr | head -n "$TOP_N"

    section "5. Apache - 429 rate-limit responses"
    awk -F '\t' '$4 == "429" && $1 != "-" { c[$1]++ } END { for (ip in c) print c[ip], ip }' "$ACCESS_TSV" \
        | sort -nr | head -n "$TOP_N"

    section "6. Apache - 5xx responses by client IP"
    awk -F '\t' -v t="$THRESH_5XX" '
        $4 ~ /^5[0-9][0-9]$/ && $1 != "-" { c[$1]++ }
        END { for (ip in c) if (c[ip] >= t) print c[ip], ip }
    ' "$ACCESS_TSV" | sort -nr | head -n "$TOP_N"

    section "7. Nextcloud desktop clients - legacy/5xx DAV activity"
    # Nextcloud desktop clients identify themselves with a mirall/<version> token.
    # Aggregate DAV/5xx activity and flag clients below NC_MIN_DESKTOP_VERSION.
    awk -F '\t' -v minver="$NC_MIN_DESKTOP_VERSION" '
        function verlt(A,B,   na,nb,n,a,b,i,ai,bi) {
            na=split(A,a,"."); nb=split(B,b,"."); n=(na>nb?na:nb)
            for (i=1;i<=n;i++) {
                ai=(i<=na ? a[i]+0 : 0); bi=(i<=nb ? b[i]+0 : 0)
                if (ai < bi) return 1
                if (ai > bi) return 0
            }
            return 0
        }
        {
            ua=$5
            low=tolower(ua)
            if (match(low, /mirall\/[0-9]+(\.[0-9]+)*/)) {
                ver=substr(low, RSTART+7, RLENGTH-7)
                user=($6=="" ? "-" : $6)
                key=$1 SUBSEP user SUBSEP ver SUBSEP $4 SUBSEP $2 SUBSEP $3
                c[key]++
                versions[$1 SUBSEP user SUBSEP ver]++
            }
        }
        END {
            found=0
            for (key in c) {
                split(key,k,SUBSEP)
                ip=k[1]; user=k[2]; ver=k[3]; status=k[4]; method=k[5]; uri=k[6]
                if (verlt(ver,minver) || status ~ /^5/) {
                    sev=(verlt(ver,minver) ? "LEGACY" : "CHECK")
                    printf "%d %s ip=%s user=%s client=%s status=%s method=%s uri=%s\n", c[key],sev,ip,user,ver,status,method,uri
                    found=1
                }
            }
            if (!found) print "No legacy or 5xx Nextcloud desktop-client activity detected."
        }
    ' "$ACCESS_TSV" | sort -nr | head -n 100

    section "8. Apache - suspicious request methods"
    # WebDAV methods used by Nextcloud are intentionally NOT flagged.
    awk -F '\t' '
        $2 ~ /^(TRACE|TRACK|CONNECT|DEBUG)$/ {
            print $1, $2, $4, $3
        }
    ' "$ACCESS_TSV" | head -n 100

    section "9. Apache - exploit/scanner URI probes"
    awk -F '\t' '
        {
            u=tolower($3)
            if (u ~ /(\/\.env([\/?]|$)|\/\.git([\/?]|$)|wp-admin|wp-login\.php|xmlrpc\.php|phpmyadmin|pma\/|\/cgi-bin\/|vendor\/phpunit|eval-stdin\.php|\/etc\/passwd|proc\/self\/environ|\.\.%2f|%2e%2e|\.\.\/|<script|%3cscript|union([+%20]|[[:space:]])+select|information_schema|sleep\([0-9]+\)|benchmark\()/)
                print $1, $4, $2, $3
        }
    ' "$ACCESS_TSV" | head -n 200

    section "10. Apache - known scanner user-agents"
    awk -F '\t' '
        {
            ua=tolower($5)
            if (ua ~ /(sqlmap|nikto|masscan|nmap scripting engine|acunetix|nessus|wpscan|gobuster|dirbuster|zgrab|nuclei|whatweb|feroxbuster)/)
                print $1, $4, $2, $5
        }
    ' "$ACCESS_TSV" | head -n 100

    section "11. Apache - top requested 404 paths"
    awk -F '\t' '$4 == "404" { c[$3]++ } END { for (u in c) print c[u], u }' "$ACCESS_TSV" \
        | sort -nr | head -n "$TOP_N"

    section "12. Apache error log - security/error indicators"
    grep -Eai \
        'client denied|access denied|AH[0-9]+:.*denied|invalid URI|script not found|File does not exist|ModSecurity|mod_security|segfault|core dump|PHP (Fatal|Parse) error|proxy_fcgi:error|Premature end of script headers|SSL Library Error|certificate.*(failed|error)|request failed|malformed|invalid method' \
        "$ERROR_RAW" | head -n 200 || true

    section "13. Apache error log - client IPs mentioned most often"
    awk '
        {
            if (match($0, /\[client[[:space:]]+[^]]+\]/)) {
                x=substr($0, RSTART, RLENGTH)
                sub(/^\[client[[:space:]]+/, "", x)
                sub(/\]$/, "", x)
                sub(/:[0-9]+$/, "", x)
                if (x != "") c[x]++
            }
        }
        END { for (ip in c) print c[ip], ip }
    ' "$ERROR_RAW" | sort -nr | head -n "$TOP_N"

    section "14. Apache mod_evasive - denied clients"
    if grep -Eqi '\[evasive20:error\]' "$ERROR_RAW"; then
        awk '
            /\[evasive20:error\]/ {
                ip="-"
                if (match($0, /\[client[[:space:]]+[^]]+\]/)) {
                    x=substr($0,RSTART,RLENGTH)
                    sub(/^\[client[[:space:]]+/,"",x); sub(/\]$/,"",x); sub(/:[0-9]+$/,"",x)
                    ip=x
                }
                c[ip]++
                last[ip]=$0
            }
            END {
                for (ip in c) {
                    scope="PUBLIC"
                    if (ip ~ /^127\./ || ip ~ /^10\./ || ip ~ /^192\.168\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[01])\./) scope="PRIVATE"
                    printf "%d %s %s\n", c[ip], scope, ip
                }
            }
        ' "$ERROR_RAW" | sort -nr | head -n "$TOP_N"
        echo
        echo "Recent examples:"
        grep -Ei '\[evasive20:error\]' "$ERROR_RAW" | tail -20 || true
    else
        echo "No mod_evasive denials in the lookback window."
    fi

    section "15. Nextcloud - login/brute-force/security messages"
    if [[ $JQ_AVAILABLE -eq 1 ]]; then
        awk -F '\t' '
            {
                m=tolower($6)
                if (m ~ /(login failed|failed login|brute.?force|invalid password|password.*invalid|two-factor.*failed|authentication.*failed|could not verify|not authenticated)/)
                    print $1, $2, $3, $4, "level=" $5, $6
            }
        ' "$NC_TSV" | head -n 200
    else
        grep -Eai \
            'login failed|failed login|brute.?force|invalid password|two-factor.*failed|authentication.*failed|could not verify' \
            "$NC_RAW" | head -n 200 || true
    fi

    section "16. Nextcloud - IPs with repeated authentication failures"
    if [[ $JQ_AVAILABLE -eq 1 ]]; then
        awk -F '\t' -v t="$THRESH_NC_AUTH" '
            {
                m=tolower($6)
                if (m ~ /(login failed|failed login|brute.?force|invalid password|password.*invalid|two-factor.*failed|authentication.*failed|could not verify|not authenticated)/ && $2 != "-")
                    c[$2]++
            }
            END { for (ip in c) if (c[ip] >= t) print c[ip], ip }
        ' "$NC_TSV" | sort -nr | head -n "$TOP_N"
    else
        echo "jq not installed: structured Nextcloud IP ranking unavailable."
    fi

    section "17. Nextcloud - security-relevant application messages"
    if [[ $JQ_AVAILABLE -eq 1 ]]; then
        awk -F '\t' '
            {
                m=tolower($6)
                if (m ~ /(trusted domain|csrf|request token|not authorized|access denied|forbidden|signature.*(invalid|failed)|certificate.*(invalid|failed)|local access rules|not allowed|security|suspicious)/)
                    print $1, $2, $3, $4, "level=" $5, $6
            }
        ' "$NC_TSV" | head -n 200
    else
        grep -Eai \
            'trusted domain|csrf|request token|not authorized|access denied|forbidden|signature.*(invalid|failed)|local access rules|suspicious' \
            "$NC_RAW" | head -n 200 || true
    fi

    section "18. Nextcloud - warnings/errors by app"
    if [[ $JQ_AVAILABLE -eq 1 ]]; then
        awk -F '\t' '$5 ~ /^[0-9]+$/ && $5 >= 2 { c[$4]++ } END { for (app in c) print c[app], app }' "$NC_TSV" \
            | sort -nr | head -n "$TOP_N"
    else
        echo "jq not installed: structured app/error statistics unavailable."
    fi

    section "19. Nextcloud - recent level >= 3 errors/fatals"
    if [[ $JQ_AVAILABLE -eq 1 ]]; then
        awk -F '\t' '$5 ~ /^[0-9]+$/ && $5 >= 3 { print $1, $2, $3, $4, "level=" $5, $6 }' "$NC_TSV" \
            | head -n 200
    else
        grep -E '"level"[[:space:]]*:[[:space:]]*[34]' "$NC_RAW" | head -n 200 || true
    fi

    section "20. Cross-check - IPs appearing in both Apache failures and Nextcloud auth failures"
    if [[ $JQ_AVAILABLE -eq 1 ]]; then
        awk -F '\t' '($4 == "401" || $4 == "403" || $4 == "404" || $4 == "429") && $1 != "-" { print $1 }' "$ACCESS_TSV" \
            | sort -u > "$TMPDIR_AUDIT/apache-bad-ips.txt"

        awk -F '\t' '
            {
                m=tolower($6)
                if (m ~ /(login failed|failed login|brute.?force|invalid password|password.*invalid|two-factor.*failed|authentication.*failed|could not verify|not authenticated)/ && $2 != "-")
                    print $2
            }
        ' "$NC_TSV" | sort -u > "$TMPDIR_AUDIT/nc-bad-ips.txt"

        comm -12 "$TMPDIR_AUDIT/apache-bad-ips.txt" "$TMPDIR_AUDIT/nc-bad-ips.txt" | head -n "$TOP_N" || true
    else
        echo "jq not installed: structured correlation unavailable."
    fi

    section "Interpretation"
    cat <<'TXT'
High-signal indicators:
  - Exploit/scanner URI probes, especially when followed by HTTP 2xx/3xx.
  - TRACE/TRACK/CONNECT/DEBUG requests from external sources.
  - Repeated Nextcloud login failures or brute-force messages from one IP.
  - The same IP appearing in both Apache failures and Nextcloud auth failures.
  - Security-relevant Nextcloud messages combined with unusual Apache activity.
  - Legacy Nextcloud desktop clients repeatedly producing DAV 5xx responses.
  - mod_evasive denials affecting expected internal or trusted clients.

Usually lower-signal/noisy by themselves:
  - A handful of 404s from arbitrary Internet scanners.
  - WebDAV methods such as PROPFIND, PUT, DELETE, MOVE, COPY, LOCK and UNLOCK.
  - A small number of 401/403 responses.
  - Nextcloud warnings/errors without a matching hostile request pattern.
  - A legacy client by itself is an operational/security-maintenance issue, not proof of compromise.

This is triage, not an IDS. Validate high-signal findings against the full source lines,
reverse proxy/CDN configuration, known admin IPs, fail2ban/CrowdSec, firewall logs,
and Nextcloud's own brute-force protection state before blocking anything.
TXT

} | tee "$REPORT_FILE"

echo
echo "Report written to: $REPORT_FILE"
