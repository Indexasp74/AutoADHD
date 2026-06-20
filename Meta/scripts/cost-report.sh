#!/bin/bash
# cost-report.sh — price the vault's agent activity at current API rates.
#
# Reads Meta/agent-token-usage.jsonl (written by invoke-agent.sh) and prints,
# per agent: runs, token totals, and the API-equivalent cost computed from
# token counts at today's published rates. Projects the observed time window
# to a 30-day month so you can compare "Pro + metered API" against flat Max.
#
# Why recompute from tokens instead of trusting the logged cost_usd: on a
# Max/Pro subscription the Claude CLI frequently reports total_cost_usd = 0
# (the run was "free"). Token counts are always populated, so we price those.
# The logged cost_usd is shown alongside as a cross-check when present.
#
# Usage: Meta/scripts/cost-report.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG="${1:-$VAULT_ROOT/Meta/agent-token-usage.jsonl}"

if [ ! -f "$LOG" ]; then
    echo "No token log at $LOG yet."
    echo "Agents haven't run, or none have logged usage. Start the schedule"
    echo "(Meta/scripts/install-cron.sh + sudo service cron start) and re-run after a day."
    exit 0
fi

python3 - "$LOG" <<'PY'
import json, sys, datetime

LOG = sys.argv[1]

# Current published API rates, USD per 1M tokens: (input, output)
RATES = {
    "opus":   (5.0, 25.0),   # claude-opus-4-8 / 4.x
    "sonnet": (3.0, 15.0),   # claude-sonnet-4-6
    "haiku":  (1.0,  5.0),   # claude-haiku-4-5
}
# Default model when the entry predates model logging or used the CLI default.
# The CLI default under this subscription is Opus-tier — price it as opus.
DEFAULT_TIER = "opus"

def tier(model):
    m = (model or "").lower()
    if "haiku" in m:  return "haiku"
    if "sonnet" in m: return "sonnet"
    if "opus" in m:   return "opus"
    return DEFAULT_TIER  # "default" or unknown

def cost(tier_name, inp, out, cache_create, cache_read):
    in_rate, out_rate = RATES[tier_name]
    # cache write ~1.25x input, cache read ~0.1x input (standard pricing)
    return (
        inp          * in_rate
        + out        * out_rate
        + cache_create * in_rate * 1.25
        + cache_read   * in_rate * 0.10
    ) / 1_000_000

rows, ts_min, ts_max = {}, None, None
logged_cost = 0.0
n = 0

with open(LOG) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        n += 1
        agent = d.get("agent", "?")
        t = tier(d.get("model"))
        key = (agent, t)
        r = rows.setdefault(key, dict(runs=0, inp=0, out=0, cc=0, cr=0, usd=0.0, logged=0.0))
        inp = d.get("input_tokens", 0) or 0
        out = d.get("output_tokens", 0) or 0
        cc  = d.get("cache_creation", 0) or 0
        cr  = d.get("cache_read", 0) or 0
        r["runs"]   += 1
        r["inp"]    += inp
        r["out"]    += out
        r["cc"]     += cc
        r["cr"]     += cr
        r["usd"]    += cost(t, inp, out, cc, cr)
        lc = d.get("cost_usd", 0) or 0
        r["logged"] += lc
        logged_cost += lc
        ts = d.get("ts")
        if ts:
            ts_min = ts if ts_min is None or ts < ts_min else ts_min
            ts_max = ts if ts_max is None or ts > ts_max else ts_max

if n == 0:
    print("Token log is present but empty — no agent runs recorded yet.")
    sys.exit(0)

# Observed window in days (min 1 so a single-day sample still projects).
span_days = 1.0
if ts_min and ts_max:
    try:
        a = datetime.datetime.fromisoformat(ts_min)
        b = datetime.datetime.fromisoformat(ts_max)
        span_days = max((b - a).total_seconds() / 86400.0, 1.0)
    except Exception:
        pass

total_usd = sum(r["usd"] for r in rows.values())

print()
print(f"AutoADHD agent cost report  —  {n} runs over {span_days:.1f} day(s)")
print(f"window: {ts_min}  →  {ts_max}")
print("priced from token counts at current API rates (opus 5/25, sonnet 3/15, haiku 1/5 per 1M)")
print("=" * 92)
print(f"{'agent':<18}{'tier':<8}{'runs':>5}{'in(K)':>9}{'out(K)':>8}{'cacheR(K)':>11}{'cost$':>10}{'$/mo':>10}")
print("-" * 92)
for (agent, t), r in sorted(rows.items(), key=lambda kv: -kv[1]["usd"]):
    permo = r["usd"] / span_days * 30
    print(f"{agent:<18}{t:<8}{r['runs']:>5}"
          f"{r['inp']/1000:>9.1f}{r['out']/1000:>8.1f}{r['cr']/1000:>11.1f}"
          f"{r['usd']:>10.3f}{permo:>10.2f}")
print("-" * 92)
print(f"{'TOTAL':<18}{'':<8}{n:>5}{'':>9}{'':>8}{'':>11}{total_usd:>10.3f}{total_usd/span_days*30:>10.2f}")
print("=" * 92)
print()
print(f"Projected monthly API cost (metered):  ${total_usd/span_days*30:,.2f}/mo")
print(f"  vs Max flat rate:                    $100.00/mo")
print(f"  vs Pro + this metered cost:          ${20 + total_usd/span_days*30:,.2f}/mo")
if logged_cost > 0:
    print()
    print(f"(cross-check: CLI-reported total_cost_usd summed to ${logged_cost:,.2f} over the window;")
    print(f" 0 is normal on a subscription — the token-based figure above is the one to trust.)")
print()
print("Note: a few days is a small sample. Let it run ~7 days for a stable projection,")
print("and remember extraction cost scales with how many voice memos you actually send.")
PY
