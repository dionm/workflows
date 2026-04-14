#!/usr/bin/env bash
# setup-gitops.sh
#
# One-time setup for GitOps-native image promotion.
# For each repo: creates ACR CD webhook (staging) and opens a PR to add
# gitops_repo to the caller workflow.
#
# Prerequisites:
#   - az CLI logged in with access to devopsmelb ACR and staging resource group
#   - gh CLI authenticated with write access to each app repo
#   - GITOPS_TOKEN already set as a secret in each repo
#
# Usage:
#   chmod +x scripts/setup-gitops.sh
#   ./scripts/setup-gitops.sh

set -euo pipefail

# ── config ───────────────────────────────────────────────────────────────────
ACR="devopsmelb"
SUBSCRIPTION="4b19ef7e-9566-478a-913d-8b1d746bd6e9"
GITOPS_REPO="dionm/homelab-gitops"
RG_STAGING="spectrum-staging-rg"

# repo -> "image_name|staging_webapp|workflow_path|base_branch"
declare -A REPOS=(
  [dionm/phc-website]="phc-app|phc-main-staging-app|.github/workflows/azure-deploy.yml|develop"
  [dionm/sh-website-gatsby]="spectrum-app|spectrum-main-staging-app|.github/workflows/azure-deploy.yml|develop"
)

# repos where the deploy job has `if: github.ref_type == 'branch'` which
# blocks tag-based promote-release; patch to also allow tag triggers
PATCH_TAG_CONDITION=(
  "dionm/phc-website"
)

# ── helpers ──────────────────────────────────────────────────────────────────
step() { echo; echo "▶ $*"; }
ok()   { echo "  ✓ $*"; }

# ── main loop ─────────────────────────────────────────────────────────────────
for REPO in "${!REPOS[@]}"; do
  IFS='|' read -r IMAGE_NAME WEBAPP WORKFLOW_PATH BASE_BRANCH <<< "${REPOS[$REPO]}"
  REPO_SHORT="${REPO#dionm/}"

  echo
  echo "══════════════════════════════════════"
  echo "  $REPO"
  echo "══════════════════════════════════════"

  # ── 1. ACR continuous deployment webhook ──────────────────────────────────
  step "ACR webhook: ${IMAGE_NAME}:staging -> ${WEBAPP}"

  WEBHOOK_URL=$(az webapp deployment container show-cd-url \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$RG_STAGING" \
    --name "$WEBAPP" \
    --query CI_CD_URL -o tsv)

  WEBHOOK_NAME="${WEBAPP}-cd"

  if az acr webhook show --registry "$ACR" --name "$WEBHOOK_NAME" &>/dev/null; then
    az acr webhook update \
      --registry "$ACR" \
      --name "$WEBHOOK_NAME" \
      --uri "$WEBHOOK_URL" \
      --actions push \
      --output none
    ok "webhook updated (already existed)"
  else
    az acr webhook create \
      --registry "$ACR" \
      --name "$WEBHOOK_NAME" \
      --uri "$WEBHOOK_URL" \
      --actions push \
      --scope "${IMAGE_NAME}:staging" \
      --output none
    ok "webhook created: scope=${IMAGE_NAME}:staging"
  fi

  # ── 2. Caller workflow: add gitops_repo input ──────────────────────────────
  step "Workflow PR: add gitops_repo to $WORKFLOW_PATH"

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT

  gh repo clone "$REPO" "$TMP" -- --depth=1 --branch "$BASE_BRANCH" 2>/dev/null

  cd "$TMP"
  git config user.name "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"

  BRANCH="chore/add-gitops-repo-input"
  git checkout -b "$BRANCH"

  # Idempotency: skip if already present
  if grep -q "gitops_repo:" "$WORKFLOW_PATH"; then
    ok "gitops_repo already present, skipping PR"
    cd - > /dev/null
    rm -rf "$TMP"
    trap - EXIT
    continue
  fi

  # Insert gitops_repo after the image_name: line in the with: block
  awk -v repo="$GITOPS_REPO" '
    /image_name:/ { print; print "      gitops_repo: " repo; next }
    1
  ' "$WORKFLOW_PATH" > "${WORKFLOW_PATH}.tmp" && mv "${WORKFLOW_PATH}.tmp" "$WORKFLOW_PATH"

  # phc-website fix: deploy job has `if: github.ref_type == 'branch'` which
  # blocks v* tag pushes from reaching promote-release in the reusable workflow
  if printf '%s\n' "${PATCH_TAG_CONDITION[@]}" | grep -qx "$REPO"; then
    sed -i '' \
      "s|if: github.ref_type == 'branch'$|if: github.ref_type == 'branch' || startsWith(github.ref, 'refs/tags/v')|" \
      "$WORKFLOW_PATH"
    ok "patched deploy job condition to include tag triggers"
  fi

  git add "$WORKFLOW_PATH"
  git commit -m "chore: add gitops_repo input for GitOps-native promotion"
  git push origin "$BRANCH"

  gh pr create \
    --repo "$REPO" \
    --base "$BASE_BRANCH" \
    --head "$BRANCH" \
    --title "chore: add gitops_repo input for GitOps-native promotion" \
    --body "Adds \`gitops_repo: ${GITOPS_REPO}\` to the reusable workflow call.

Production and release deploys will now open PRs in \`${GITOPS_REPO}\` rather
than calling \`az webapp config container set\` directly. ArgoCD reconciles on merge.

Requires \`GITOPS_TOKEN\` secret (already set)."

  ok "PR opened"

  cd - > /dev/null
  rm -rf "$TMP"
  trap - EXIT
done

echo
echo "══════════════════════════════════════"
echo "  Done"
echo "══════════════════════════════════════"
echo
echo "Remaining manual steps:"
echo "  1. Review and merge the PRs opened above"
echo "  2. thrive-website uses a custom workflow (azure/webapps-deploy) -"
echo "     requires separate migration to adopt the reusable workflow first"
echo "  3. emmarose-psychologist, trailhead, thivepaediatrics not included -"
echo "     add their config to REPOS above once webapp/RG details are known"
