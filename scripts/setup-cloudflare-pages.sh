#!/usr/bin/env bash
# setup-cloudflare-pages.sh — one-time Cloudflare Pages setup for hannoknatz.com
#
# Mirrors the infrastructure of bullshitbox.ai / gatino.org / levelzerocontext.com:
#   - Cloudflare Pages project, git-connected to Level-Zero-Context/hannoknatz.com
#   - production branch: main, no build step (static files at repo root)
#   - custom domains: hannoknatz.com + www.hannoknatz.com
#   - DNS: CNAME hannoknatz.com -> hannoknatz-com.pages.dev (proxied, apex-flattened)
#          CNAME www.hannoknatz.com -> hannoknatz.com (proxied)
#
# Usage:
#   CLOUDFLARE_API_TOKEN=... ./scripts/setup-cloudflare-pages.sh
#   (optional: CLOUDFLARE_ACCOUNT_ID=... to skip auto-detection)
#
# Token permissions needed:
#   Account / Cloudflare Pages / Edit
#   Account / Account Settings / Read
#   Zone    / DNS               / Edit
#   Zone    / Zone              / Read
#
# If project creation fails with a GitHub access error, add the repo to the
# Cloudflare Pages GitHub App first:
#   GitHub -> Level-Zero-Context -> Settings -> GitHub Apps -> Cloudflare Pages
#   -> Configure -> Repository access -> add hannoknatz.com
# Then re-run this script (it is idempotent).

set -euo pipefail

DOMAIN="hannoknatz.com"
PROJECT="hannoknatz-com"
GITHUB_OWNER="Level-Zero-Context"
GITHUB_REPO="hannoknatz.com"
PROD_BRANCH="main"

: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN (Account: Pages Edit, Zones: DNS Edit + Read)}"

api() {
  local method="$1" url="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -X "$method" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$body" "$url"
  else
    curl -sS -X "$method" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      "$url"
  fi
}

ok()   { jq -r '.success' <<< "$1" | grep -q true; }
fail() { jq -r '.errors[]? | "\(.code): \(.message)"' <<< "$1"; }

BASE="https://api.cloudflare.com/client/v4"

# --- account id -------------------------------------------------------------
if [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
  R=$(api GET "$BASE/accounts")
  ok "$R" || { echo "ERROR: cannot list accounts: $(fail "$R")"; exit 1; }
  CLOUDFLARE_ACCOUNT_ID=$(jq -r '.result[0].id' <<< "$R")
fi
echo "account: $CLOUDFLARE_ACCOUNT_ID"

# --- zone id ----------------------------------------------------------------
R=$(api GET "$BASE/zones?name=$DOMAIN")
ok "$R" || { echo "ERROR: cannot read zone $DOMAIN: $(fail "$R")"; exit 1; }
ZONE_ID=$(jq -r '.result[0].id' <<< "$R")
[ "$ZONE_ID" != "null" ] || { echo "ERROR: zone $DOMAIN not in this account"; exit 1; }
echo "zone:    $ZONE_ID"

# --- pages project (git-connected) ------------------------------------------
BODY=$(jq -n \
  --arg name "$PROJECT" --arg branch "$PROD_BRANCH" \
  --arg owner "$GITHUB_OWNER" --arg repo "$GITHUB_REPO" \
  '{name: $name, production_branch: $branch,
    source: {type: "github", owner: $owner, repo_name: $repo,
             config: {deployments_enabled: true,
                      production_deployments_enabled: true,
                      production_branch: $branch,
                      pr_comments_enabled: true,
                      preview_deployment_setting: "all"}}}')
R=$(api POST "$BASE/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects" "$BODY")
if ok "$R"; then
  echo "pages project: created  ($PROJECT)"
else
  if fail "$R" | grep -qiE "already exists|10006"; then
    echo "pages project: exists   ($PROJECT)"
  else
    echo "ERROR: project creation failed: $(fail "$R")"
    exit 1
  fi
fi

# --- custom domains ----------------------------------------------------------
for D in "$DOMAIN" "www.$DOMAIN"; do
  R=$(api POST "$BASE/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$PROJECT/domains" \
       "$(jq -n --arg d "$D" '{name: $d}')")
  if ok "$R"; then
    echo "custom domain: created  ($D)"
  elif fail "$R" | grep -qiE "already|duplicate"; then
    echo "custom domain: exists   ($D)"
  else
    echo "WARN: custom domain $D: $(fail "$R")"
  fi
done

# --- DNS records (idempotent) ------------------------------------------------
add_record() {
  local name="$1" target="$2"
  R=$(api GET "$BASE/zones/$ZONE_ID/dns_records?type=CNAME&name=$name")
  if ok "$R" && [ "$(jq '.result | length' <<< "$R")" != "0" ]; then
    echo "dns:           exists   ($name)"
    return
  fi
  R=$(api POST "$BASE/zones/$ZONE_ID/dns_records" \
       "$(jq -n --arg n "$name" --arg t "$target" \
          '{type: "CNAME", name: $n, content: $t, proxied: true}')")
  if ok "$R"; then
    echo "dns:           created  ($name -> $target, proxied)"
  else
    echo "ERROR: dns $name: $(fail "$R")"; exit 1
  fi
}
add_record "$DOMAIN" "$PROJECT.pages.dev"
add_record "www.$DOMAIN" "$DOMAIN"

# --- first deployment ---------------------------------------------------------
echo
echo "waiting for the first git deployment (may take a minute)..."
for i in $(seq 1 24); do
  R=$(api GET "$BASE/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$PROJECT/deployments")
  ST=$(jq -r '.result[0].latest_stage.status // "none"' <<< "$R" 2>/dev/null)
  URL=$(jq -r '.result[0].url // "-"' <<< "$R" 2>/dev/null)
  echo "  [$i] $ST  ($URL)"
  [ "$ST" = "success" ] && break
  [ "$ST" = "failure" ] && { echo "deployment failed — check dashboard"; exit 1; }
  sleep 10
done

echo
echo "done. verify:"
echo "  https://$PROJECT.pages.dev"
echo "  https://$DOMAIN"
