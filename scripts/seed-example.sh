#!/bin/sh
# Seed an example company so you can watch O v4 work right away.
# Uses the `sim` runtime — no tokens spent, no API keys needed.
#
#   ./scripts/seed-example.sh           # against http://localhost:4100
#   O_API=http://host:4100 ./scripts/seed-example.sh
set -e

API="${O_API:-http://localhost:4100}"

if ! curl -s "$API/api/health" >/dev/null 2>&1; then
  echo "error: O v4 daemon not reachable at $API — start it first (swarmd)"
  exit 1
fi

extract_id() { sed -n 's/.*"id":"\([^"]*\)".*/\1/p'; }

CO=$(curl -s -X POST "$API/api/companies" \
  -d '{"name":"Demo Co","mission":"prove O v4 runs a company end to end","issue_prefix":"DEMO","budget_monthly_cents":100000}' \
  | extract_id)
echo "created company  Demo Co  ($CO)"

curl -s -X POST "$API/api/companies/$CO/agents" \
  -d '{"name":"Pilot","role":"engineer","runtime":"sim"}' >/dev/null
echo "hired agent      Pilot (sim runtime)"

for title in \
  "Set up the project repository" \
  "Draft the landing page copy" \
  "Wire the analytics events" \
  "Write the onboarding email" \
  "Fix the flaky checkout test" \
  "Plan the launch announcement"
do
  curl -s -X POST "$API/api/companies/$CO/issues" \
    -d "{\"title\":\"$title\",\"priority\":\"medium\"}" >/dev/null
  echo "filed issue      $title"
done

echo
echo "done — open the dashboard and watch them flow Backlog -> Done:"
echo "  $API"
