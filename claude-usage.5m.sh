#!/usr/bin/env bash
# Claude Code Usage - Argos Plugin v3
# Compact display of Claude Code usage statistics
# Refresh: every 5 minutes

# Note: Pas de "set -euo pipefail" pour éviter que le menu Argos se fige en cas d'erreur
export LC_NUMERIC=C

# ============================================================================
# CONFIGURATION
# ============================================================================

STATS_FILE="$HOME/.claude/stats-cache.json"
CREDENTIALS_FILE="$HOME/.claude/.credentials.json"

# API Pricing (per million tokens) - January 2026
declare -A INPUT_PRICE=(["claude-opus-4-5-20251101"]=5.00 ["claude-sonnet-4-5-20250929"]=3.00)
declare -A OUTPUT_PRICE=(["claude-opus-4-5-20251101"]=25.00 ["claude-sonnet-4-5-20250929"]=15.00)
declare -A CACHE_READ_PRICE=(["claude-opus-4-5-20251101"]=0.50 ["claude-sonnet-4-5-20250929"]=0.30)
declare -A CACHE_WRITE_PRICE=(["claude-opus-4-5-20251101"]=6.25 ["claude-sonnet-4-5-20250929"]=3.75)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

format_tokens() {
    local num="${1:-0}"
    [[ ! "$num" =~ ^[0-9]+$ ]] && num=0
    if (( num >= 1000000 )); then
        printf "%.1fM" "$(echo "scale=1; $num / 1000000" | bc 2>/dev/null || echo "0")"
    elif (( num >= 1000 )); then
        printf "%.0fK" "$(echo "scale=0; $num / 1000" | bc 2>/dev/null || echo "0")"
    else
        printf "%d" "$num"
    fi
}

format_cost() {
    local amount="${1:-0}"
    [[ ! "$amount" =~ ^[0-9.]+$ ]] && amount=0
    printf "\$%.0f" "$amount"
}

format_cost_detail() {
    local amount="${1:-0}"
    [[ ! "$amount" =~ ^[0-9.]+$ ]] && amount=0
    printf "\$%'.0f" "$amount" | sed 's/,/ /g'
}

get_model_short() {
    case "$1" in
        *opus*) echo "Opus" ;;
        *sonnet*) echo "Sonnet" ;;
        *haiku*) echo "Haiku" ;;
        *) echo "—" ;;
    esac
}

sparkline() {
    local -a values=("$@")
    local chars=("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")
    local max=1 spark="" idx v
    [[ ${#values[@]} -eq 0 ]] && { echo "▁▁▁▁▁▁▁"; return; }
    for v in "${values[@]}"; do
        [[ "$v" =~ ^[0-9]+$ ]] && (( v > max )) && max=$v
    done
    for v in "${values[@]}"; do
        [[ ! "$v" =~ ^[0-9]+$ ]] && v=0
        idx=$(( (v * 7) / max ))
        (( idx > 7 )) && idx=7
        spark+="${chars[$idx]}"
    done
    echo "$spark"
}

# ============================================================================
# DATA LOADING
# ============================================================================

if [[ ! -f "$STATS_FILE" ]]; then
    echo "󰧑  — | color=#888888"
    echo "---"
    echo "Pas de données Claude Code"
    exit 0
fi

stats=$(cat "$STATS_FILE")
today=$(date +%Y-%m-%d)

# Extract all daily data in a single jq call (optimized)
daily_data=$(echo "$stats" | jq -c '
    [.dailyModelTokens[]? | {date: .date, tokens: (.tokensByModel | to_entries | map(.value) | add // 0)}]
' 2>/dev/null) || daily_data="[]"

# Today's tokens
today_tokens=$(echo "$daily_data" | jq -r --arg d "$today" '.[] | select(.date == $d) | .tokens // 0')
today_tokens=${today_tokens:-0}

# Primary model today
primary_model=$(echo "$stats" | jq -r --arg d "$today" '
    .dailyModelTokens[] | select(.date == $d) | .tokensByModel |
    to_entries | max_by(.value) | .key // empty')
[[ -z "$primary_model" ]] && primary_model=$(echo "$stats" | jq -r '.dailyModelTokens[-1].tokensByModel | to_entries | max_by(.value) | .key // empty')

# Week tokens + sparkline data (optimized: single jq call)
week_start=$(date -d "6 days ago" +%Y-%m-%d)
week_json=$(echo "$daily_data" | jq -c --arg start "$week_start" '
    [.[]? | select(.date >= $start) | {date: .date, tokens: .tokens}] | sort_by(.date)
' 2>/dev/null) || week_json="[]"

declare -a week_data=()
week_tokens=0
for i in {6..0}; do
    d=$(date -d "$i days ago" +%Y-%m-%d)
    t=$(echo "$week_json" | jq -r --arg d "$d" '.[] | select(.date == $d) | .tokens // 0')
    t=${t:-0}
    week_data+=("$t")
    week_tokens=$((week_tokens + t))
done

# Month tokens (optimized: single jq call)
month_start=$(date -d "29 days ago" +%Y-%m-%d)
month_tokens=$(echo "$daily_data" | jq -r --arg start "$month_start" '
    [.[] | select(.date >= $start) | .tokens] | add // 0
')
month_tokens=${month_tokens:-0}

# Total tokens & days
total_tokens=$(echo "$stats" | jq '[.dailyModelTokens[]?.tokensByModel | to_entries[]?.value] | add // 0' 2>/dev/null) || total_tokens=0
first_date=$(echo "$stats" | jq -r '.firstSessionDate // ""' | cut -d'T' -f1)
if [[ -n "$first_date" ]]; then
    days_since=$(( ($(date +%s) - $(date -d "$first_date" +%s)) / 86400 ))
else
    days_since=0
fi

# Active Claude instances (excluding subprocesses)
active=$(pgrep -c "^claude$" 2>/dev/null || echo "0")

# Subscription
sub=$(jq -r '.claudeAiOauth.subscriptionType // "—"' "$CREDENTIALS_FILE" 2>/dev/null | sed 's/max/Max/;s/pro/Pro/')

# Last project
last_project=$(ls -t ~/.claude/projects/*/sessions-index.json 2>/dev/null | head -1 | xargs -I {} jq -r '.entries[0].projectPath // ""' {} 2>/dev/null | xargs basename 2>/dev/null || echo "")

# ============================================================================
# COST CALCULATION (optimized: single jq call for all model data)
# ============================================================================

calc_total_cost() {
    local cost=0
    local model_data
    model_data=$(echo "$stats" | jq -c '.modelUsage | to_entries[]?' 2>/dev/null) || model_data=""

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local model i o cr cw mc
        model=$(echo "$entry" | jq -r '.key')
        [[ -z "$model" || "$model" == "null" ]] && continue

        i=$(echo "$entry" | jq -r '.value.inputTokens // 0')
        o=$(echo "$entry" | jq -r '.value.outputTokens // 0')
        cr=$(echo "$entry" | jq -r '.value.cacheReadInputTokens // 0')
        cw=$(echo "$entry" | jq -r '.value.cacheCreationInputTokens // 0')

        mc=$(echo "scale=2; ($i * ${INPUT_PRICE[$model]:-5} + $o * ${OUTPUT_PRICE[$model]:-25} + $cr * ${CACHE_READ_PRICE[$model]:-0.5} + $cw * ${CACHE_WRITE_PRICE[$model]:-6.25}) / 1000000" | bc 2>/dev/null) || mc=0
        cost=$(echo "scale=2; $cost + $mc" | bc 2>/dev/null) || cost=$cost
    done <<< "$model_data"
    echo "$cost"
}

total_cost=$(calc_total_cost 2>/dev/null) || total_cost=0
total_daily=$(echo "$stats" | jq '[.dailyModelTokens[]?.tokensByModel | to_entries[]?.value] | add // 1' 2>/dev/null) || total_daily=1

# Proportional costs
cost_week=$(echo "scale=0; $total_cost * $week_tokens / $total_daily" | bc 2>/dev/null || echo "0")
cost_month=$(echo "scale=0; $total_cost * $month_tokens / $total_daily" | bc 2>/dev/null || echo "0")

# ============================================================================
# OUTPUT - PANEL
# ============================================================================

model_short=$(get_model_short "$primary_model")
week_display=$(format_tokens "$week_tokens")

# Panel: tokens week | model | cost/week
# Show active sessions count only if > 2 (script + at least 2 claude instances)
if (( active > 2 )); then
    echo "󰧑  ${week_display} │ ${model_short} │   ${active}"
else
    echo "󰧑  ${week_display} │ ${model_short} │ $(format_cost "$cost_week")/w"
fi

# ============================================================================
# OUTPUT - DROPDOWN
# ============================================================================

echo "---"
echo "  Claude Code  ${sub} | size=11"
echo "---"

# Activity section - adjust hierarchy based on today's tokens
echo "ACTIVITÉ | color=#888888 size=9"
if (( today_tokens > 0 )); then
    echo "├─ Aujourd'hui   $(format_tokens "$today_tokens") | font=monospace"
    echo "├─ Semaine       $(format_tokens "$week_tokens")  $(sparkline "${week_data[@]}") | font=monospace"
else
    echo "├─ Semaine       $(format_tokens "$week_tokens")  $(sparkline "${week_data[@]}") | font=monospace"
fi
echo "└─ Total         $(format_tokens "$total_tokens")  (${days_since}j) | font=monospace"
echo "---"

# Savings section
echo "ÉCONOMIES vs API | color=#888888 size=9"
echo "├─ Semaine       $(format_cost_detail "$cost_week") | font=monospace color=#4CAF50"
echo "├─ Mois          $(format_cost_detail "$cost_month") | font=monospace color=#4CAF50"
echo "└─ Total         $(format_cost_detail "$total_cost") | font=monospace color=#4CAF50"
echo "---"

# Current project
if [[ -n "$last_project" ]]; then
    echo "  $last_project | font=monospace"
    echo "---"
fi

# Actions
echo "󰔃  Voir usage sur claude.ai | href=https://claude.ai/settings/usage"
echo "󰅂  Rafraîchir | refresh=true"
