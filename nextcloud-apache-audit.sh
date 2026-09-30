#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only Apache + Nextcloud security/anomaly triage.

NEXTCLOUD_LOG_DIR="${NEXTCLOUD_LOG_DIR:-${1:-/var/log/nextcloud}}"
APACHE_LOG_DIR="${APACHE_LOG_DIR:-${2:-/var/log/apache2}}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
TOP_N="${TOP_N:-25}"
REPORT_DIR="${REPORT_DIR:-/tmp}"

THRESH_404="${THRESH_404:-30}"
THRESH_AUTH_HTTP="${THRESH_AUTH_HTTP:-20}"
THRESH_5XX="${THRESH_5XX:-20}"
THRESH_NC_AUTH="${THRESH_NC_AUTH:-8}"
THRESH_TOTAL_REQUESTS="${THRESH_TOTAL_REQUESTS:-5000}"

usage() {
    cat <<EOF2
Usage: $0 [NEXTCLOUD_LOG_DIR] [APACHE_LOG_DIR]

Environment overrides:
  LOOKBACK_HOURS=24
  TOP_N=25
  REPORT_DIR=/tmp
EOF2
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ ! "$LOOKBACK_HOURS" =~ ^[0-9]+$ ]] || (( LOOKBACK_HOURS < 1 )); then
    echo "ERROR: LOOKBACK_HOURS must be a positive integer." >&2
    exit 1
fi

for cmd in awk grep sort find date gzip mktemp tee wc head tail comm; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $cmd" >&2
        exit 1
    }
done

[[ -d "$APACHE_LOG_DIR" ]] || { echo "ERROR: Apache log directory not found: $APACHE_LOG_DIR" >&2; exit 1; }
[[ -d "$NEXTCLOUD_LOG_DIR" ]] || { echo "ERROR: Nextcloud log directory not found: $NEXTCLOUD_LOG_DIR" >&2; exit 1; }

mkdir -p "$REPORT_DIR"
umask 077
TMPDIR_AUDIT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_AUDIT"' EXIT
REPORT_FILE="$REPORT_DIR/nextcloud-apache-audit-$(date '+%Y%m%d-%H%M%S').txt"

ACCESS_RAW="$TMPDIR_AUDIT/access.log"
ERROR_RAW="$TMPDIR_AUDIT/error.log"
NC_RAW="$TMPDIR_AUDIT/nextcloud.log"
ACCESS_TSV="$TMPDIR_AUDIT/access.tsv"
NC_TSV="$TMPDIR_AUDIT/nextcloud.tsv"

stream_recent_logs() {
    local dir="$1"
    local pattern="$2"
    local minutes=$((LOOKBACK_HOURS * 60 + 60))
    local file

    while IFS= read -r -d '' file; do
        case "$file" in
            *.gz) gzip -cd -- "$file" 2>/dev/null || true ;;
            *) cat -- "$file" 2>/dev/null || true ;;
        esac
    done < <(find "$dir" -maxdepth 1 -type f -name "$pattern" -mmin "-$minutes" -print0 2>/dev/null | sort -z)
}

stream_recent_logs "$APACHE_LOG_DIR" '*access*log*' > "$ACCESS_RAW"
stream_recent_logs "$APACHE_LOG_DIR" '*error*log*' > "$ERROR_RAW"
stream_recent_logs "$NEXTCLOUD_LOG_DIR" 'nextcloud*.log*' > "$NC_RAW"

# Parse common/vhost-combined Apache lines into:
# IP<TAB>METHOD<TAB>URI<TAB>STATUS<TAB>USER_AGENT
awk '
BEGIN { OFS="\t" }
{
    prefix=$0
    sub(/\[.*/, "", prefix)
    n=split(prefix, a, /[[:space:]]+/)
    ip="-"
    for (i=n; i>=1; i--) {
        if (a[i] ~ /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/ || (a[i] ~ /:/ && a[i] ~ /^[0-9A-Fa-f:]+$/)) {
            ip=a[i]
            break
        }
    }

    qn=split($0, q, /"/)
    if (qn < 3) next

    rn=split(q[2], r, /[[:space:]]+/)
    method=(rn >= 1 ? r[1] : "-")
    uri=(rn >= 2 ? r[2] : "-")

    status="-"
    if (match(q[3], /[[:space:]][0-9][0-9][0-9][[:space:]]/)) status=substr(q[3], RSTART+1, 3)

    ua=(qn >= 6 ? q[6] : "-")
    gsub(/[\t\r\n]/, " ", ua)
    gsub(/[\t\r\n]/, " ", uri)
    print ip, method, uri, status, ua
}
' "$ACCESS_RAW" > "$ACCESS_TSV"

JQ_AVAILABLE=0
if command -v jq >/dev/null 2>&1; then
    JQ_AVAILABLE=1
    jq -Rr '
        fromjson?
        | select(type == "object")
        | [(.time // "-"), (.remoteAddr // "-"), (.user // "-"), (.app // "-"), ((.level // 0) | tostring), ((.message // "") | tostring | gsub("[\\t\\r\\n]"; " "))]
        | @tsv
    ' "$NC_RAW" > "$NC_TSV" 2>/dev/null || true
else
    : > "$NC_TSV"
fi

section() {
    printf '\n================================================================================\n%s\n================================================================================\n' "$1"
}

# head intentionally truncates long pipelines, so do not treat SIGPIPE as fatal here.
set +o pipefail

{
    echo "Apache + Nextcloud security/anomaly report"
    echo "Generated: $(date --iso-8601=seconds)"
    echo "Lookback files: approximately ${LOOKBACK_HOURS} hours"
    echo "Apache log directory: $APACHE_LOG_DIR"
    echo "Nextcloud log directory: $NEXTCLOUD_LOG_DIR"
    echo "Apache access rows: $(wc -l < "$ACCESS_RAW")"
    echo "Apache error rows: $(wc -l < "$ERROR_RAW")"
    echo "Nextcloud rows: $(wc -l < "$NC_RAW")"

    section "1. Top Apache client IPs"
    awk -F '\t' '$1 != "-" { c[$1]++ } END { for (ip in c) print c[ip], ip }' "$ACCESS_TSV" | sort -nr | head -n "$TOP_N"

    section "2. High request volume"
    awk -F '\t' -v t="$THRESH_TOTAL_REQUESTS" '$1 != "-" { c[$1]++ } END { for (ip in c) if (c[ip] >= t) print c[ip], ip }' "$ACCESS_TSV" | sort -nr

    section "3. Repeated 401/403 responses"
    awk -F '\t' -v t="$THRESH_AUTH_HTTP" '($4 == "401" || $4 == "403") && $1 != "-" { c[$1]++ } END { for (ip in c) if (c[ip] >= t) print c[ip], ip }' "$ACCESS_TSV" | sort -nr | head -n "$TOP_N"

    section "4. Repeated 404 responses"
    awk -F '\t' -v t="$THRESH_404" '$4 == "404" && $1 != "-" { c[$1]++ } END { for (ip in c) if (c[ip] >= t) print c[ip], ip }' "$ACCESS_TSV" | sort -nr | head -n "$TOP_N"

    section "5. Repeated 5xx responses"
    awk -F '\t' -v t="$THRESH_5XX" '$4 ~ /^5[0-9][0-9]$/ && $1 != "-" { c[$1]++ } END { for (ip in c) if (c[ip] >= t) print c[ip], ip }' "$ACCESS_TSV" | sort -nr | head -n "$TOP_N"

    section "6. Suspicious HTTP methods"
    awk -F '\t' '$2 ~ /^(TRACE|TRACK|CONNECT|DEBUG)$/ { print $1, $4, $2, $3 }' "$ACCESS_TSV" | head -n 100

    section "7. Common exploit/scanner probes"
    awk -F '\t' '
        {
            u=tolower($3)
            if (u ~ /(\/\.env([\/?]|$)|\/\.git([\/?]|$)|wp-admin|wp-login\.php|xmlrpc\.php|phpmyadmin|\/cgi-bin\/|vendor\/phpunit|eval-stdin\.php|\/etc\/passwd|proc\/self\/environ|\.\.\/|%2e%2e|sqlmap)/)
                print $1, $4, $2, $3
        }
    ' "$ACCESS_TSV" | head -n 200

    section "8. Known scanner user-agents"
    awk -F '\t' '
        {
            ua=tolower($5)
            if (ua ~ /(sqlmap|nikto|masscan|nmap scripting engine|acunetix|nessus|wpscan|gobuster|dirbuster|zgrab|nuclei|whatweb|feroxbuster)/)
                print $1, $4, $2, $5
        }
    ' "$ACCESS_TSV" | head -n 100

    section "9. mod_evasive denials"
    grep -Ei '\[evasive20:error\]' "$ERROR_RAW" | tail -n 100 || true

    section "10. Apache security/error indicators"
    grep -Eai 'client denied|access denied|invalid URI|script not found|File does not exist|ModSecurity|segfault|PHP (Fatal|Parse) error|proxy_fcgi:error|SSL Library Error|request failed|malformed|invalid method' "$ERROR_RAW" | head -n 200 || true

    section "11. Nextcloud authentication/security failures"
    if [[ $JQ_AVAILABLE -eq 1 ]]; then
        awk -F '\t' '
            {
                m=tolower($6)
                if (m ~ /(login failed|failed login|brute.?force|invalid password|password.*invalid|two-factor.*failed|authentication.*failed|could not verify|not authenticated)/)
                    print $1, $2, $3, $4, "level=" $5, $6
            }
        ' "$NC_TSV" | head -n 200
    else
        grep -Eai 'login failed|failed login|brute.?force|invalid password|two-factor.*failed|authentication.*failed|could not verify' "$NC_RAW" | head -n 200 || true
    fi

    section "12. Nextcloud IPs with repeated authentication failures"
    if [[ $JQ_AVAILABLE -eq 1 ]]; then
        awk -F '\t' -v t="$THRESH_NC_AUTH" '
            {
                m=tolower($6)
                if (m ~ /(login failed|failed login|brute.?force|invalid password|password.*invalid|two-factor.*failed|authentication.*failed|could not verify|not authenticated)/ && $2 != "-") c[$2]++
            }
            END { for (ip in c) if (c[ip] >= t) print c[ip], ip }
        ' "$NC_TSV" | sort -nr | head -n "$TOP_N"
    else
        echo "jq not installed: structured Nextcloud IP ranking unavailable."
    fi

    section "13. Cross-check Apache failures and Nextcloud auth failures"
    if [[ $JQ_AVAILABLE -eq 1 ]]; then
        awk -F '\t' '($4 == "401" || $4 == "403" || $4 == "404" || $4 == "429") && $1 != "-" { print $1 }' "$ACCESS_TSV" | sort -u > "$TMPDIR_AUDIT/apache-bad-ips.txt"
        awk -F '\t' '
            {
                m=tolower($6)
                if (m ~ /(login failed|failed login|brute.?force|invalid password|password.*invalid|two-factor.*failed|authentication.*failed|could not verify|not authenticated)/ && $2 != "-") print $2
            }
        ' "$NC_TSV" | sort -u > "$TMPDIR_AUDIT/nc-bad-ips.txt"
        comm -12 "$TMPDIR_AUDIT/apache-bad-ips.txt" "$TMPDIR_AUDIT/nc-bad-ips.txt" | head -n "$TOP_N" || true
    else
        echo "jq not installed: structured correlation unavailable."
    fi

    section "Interpretation"
    cat <<'TXT'
This is a triage helper, not an IDS. A few Internet 404s or WebDAV methods are not proof of compromise.
Higher-signal findings include repeated authentication failures, exploit probes, unusual methods, scanner user-agents,
mod_evasive denials, and the same source IP appearing in both Apache and Nextcloud failure data.
Review the original logs before blocking anything.
TXT
} | tee "$REPORT_FILE"

echo
echo "Report written to: $REPORT_FILE"
