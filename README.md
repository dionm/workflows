# dionm/workflows

Shared GitHub Actions reusable workflows for Azure App Service container deployments.

## `azure-app-service-deploy.yml`

Builds an app into a Docker image, pushes to ACR, and deploys to Azure App Service.
Supports both Node.js-built sites (Gatsby, etc.) and plain static HTML sites.

Implements a **build-once, promote-artefact** pattern: the image is built on `develop`,
then retagged (not rebuilt) for each subsequent promotion. Production and release deploys
open a PR in the caller-supplied `gitops_repo`; ArgoCD reconciles on merge.

### Tag strategy

| Trigger | Tags pushed | Deploys via |
|---|---|---|
| PR | `pr-<number>` | not deployed |
| `develop` push | `staging` + `staging-<sha7>` | ACR webhook restarts staging App Service |
| `main` push | `production-<sha7>` (retag of staging) | PR to `gitops_repo`; ArgoCD reconciles on merge |
| `v*.*.*` tag | `v1.2.3` + `v1.2` (retag of production) | PR to `gitops_repo`; ArgoCD reconciles on merge |

The `:staging` tag is floating (updated on every develop push). The App Service is
configured once to point to `:staging` permanently; ACR continuous deployment handles
the restart. All other tags are immutable.

### Promotion flow

```
PR (build + test)
  -> develop push: build image, push :staging + :staging-<sha7>
       ACR webhook -> staging App Service restarts automatically
  -> main push: retag :staging-<sha7> as :production-<sha7>
       open PR in gitops_repo -> Teams notification with PR link
       merge PR -> ArgoCD reconciles -> production App Service updated
  -> v* tag: retag :production-<sha7> as :v1.2.3 + :v1.2
       open PR in gitops_repo -> Teams notification with PR link
       merge PR -> ArgoCD reconciles -> production App Service updated
```

### Usage

```yaml
jobs:
  deploy:
    uses: dionm/workflows/.github/workflows/azure-app-service-deploy.yml@v1
    with:
      image_name: my-app            # required
      service_name: my-service      # required
      gitops_repo: org/my-gitops    # recommended; omit for legacy direct-deploy
      run_build: true               # false for plain static HTML sites
    secrets: inherit
```

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `image_name` | yes | | ACR image name (e.g. `spectrum-app`) |
| `service_name` | yes | | Passed as `SERVICE_NAME` Dockerfile build-arg |
| `gitops_repo` | no | `''` | GitOps repo for production/release PRs (e.g. `org/homelab-gitops`). When empty, falls back to legacy direct `az webapp` deploy |
| `node_version` | no | `20` | Node.js version (ignored when `run_build: false`) |
| `run_build` | no | `true` | Run `npm install` + build before Docker. Set `false` for static HTML sites |
| `build_command` | no | `npm run build` | Build command (ignored when `run_build: false`) |
| `dockerfile` | no | `Dockerfile.hybrid` | Dockerfile for CI/CD builds |
| `health_check_path` | no | `/health` | HTTP path polled after each deploy (legacy path only) |
| `gatsby_validation` | no | `false` | Fail if deprecated `gatsby-image` import found |
| `environment` | no | `''` | Manual override: `staging` or `production` |
| `skip_tests` | no | `false` | Skip the test job |

### Required secrets

Pass via `secrets: inherit` or explicitly.

| Secret | Required | Shared/per-repo | Description |
|---|---|---|---|
| `AZURE_CLIENT_ID` | yes | shared (see OIDC section) | OIDC app registration client ID |
| `AZURE_TENANT_ID` | yes | shared | Entra ID tenant |
| `AZURE_SUBSCRIPTION_ID` | yes | shared | Azure subscription |
| `ACR_LOGIN_SERVER` | yes | shared | ACR hostname (e.g. `myacr.azurecr.io`) |
| `GITOPS_TOKEN` | when `gitops_repo` set | per-repo or org | Fine-grained PAT: `Contents: write` + `Pull requests: write` on the gitops repo only |
| `RESOURCE_GROUP_STAGING` | legacy only | per-repo | |
| `RESOURCE_GROUP_PRODUCTION` | legacy only | per-repo | |
| `WEBAPP_NAME_STAGING` | legacy only | per-repo | |
| `WEBAPP_NAME_PRODUCTION` | legacy only | per-repo | |
| `TEAMS_WEBHOOK_URL` | no | optional | Teams incoming webhook for notifications |

### ACR continuous deployment (staging)

Configure a webhook from ACR to the staging App Service so that pushing `:staging`
triggers an automatic container restart. No deploy step is needed in this workflow.

```bash
# Get the CD webhook URL from the App Service
WEBHOOK_URL=$(az webapp deployment container show-cd-url \
  --resource-group <rg-staging> \
  --name <webapp-staging> \
  --query CI_CD_URL -o tsv)

# Register the webhook in ACR
az acr webhook create \
  --registry <acr-name> \
  --name <webapp-staging>-cd \
  --uri "$WEBHOOK_URL" \
  --actions push \
  --scope <image-name>:staging
```

Repeat for each app. The scope `<image-name>:staging` ensures only pushes to the
`:staging` tag trigger the webhook.

### Jobs

| Job | Trigger | Description |
|---|---|---|
| `test` | all (unless skipped) | lint, unit tests, Gatsby validation, security audit |
| `build` | all | builds image on develop/PR; retags on main/v* |
| `promote-production` | `main` push | retags staging image, opens PR in gitops_repo (or direct deploy if not set) |
| `promote-release` | `v*` tag push | retags production image as semver, opens PR in gitops_repo (or direct deploy if not set) |

---

## OIDC Authentication

All repos authenticate to Azure via OIDC (Workload Identity Federation). No stored
passwords required. Two app registrations in the **DevOps Melbourne** Entra ID tenant
hold the federated credentials. Set `AZURE_CLIENT_ID` to the client ID of whichever
app has federated credentials configured for your repo.

### `github-actions-spectrum` — full (20/20)

Client ID: `1de386f0-fba3-449b-84e4-4767634c415e`

| Repo | Configured subjects |
|---|---|
| `dionm/phc-website` | develop, main, tags/*, environment:staging, environment:production |
| `dionm/thrive-website` | develop, main, tags/*, environment:staging, environment:production |
| `dionm/emmarose-psychologist` | develop, main, tags/*, environment:staging, environment:production |
| `dionm/trailhead` | develop, main, tags/*, environment:staging, environment:production |

### `gh-actions-sh-website` — 10/20 slots used

Client ID: `1c1e36be-fdcf-48f1-a92d-9ea87a97584e`

| Repo | Configured subjects |
|---|---|
| `dionm/sh-website-gatsby` | develop, main, tags/*, environment:staging, environment:production |
| `dionm/thivepaediatrics` | develop, main, tags/*, environment:staging, environment:production |

### Adding a new repo

1. Use `gh-actions-sh-website` (10 free slots) or create a new app registration if full.
2. Add 5 federated credentials:

```bash
OBJ_ID=$(az ad app show --id <client-id> --query id -o tsv)
for subject in \
  "repo:dionm/<repo>:ref:refs/heads/develop" \
  "repo:dionm/<repo>:ref:refs/heads/main" \
  "repo:dionm/<repo>:ref:refs/tags/*" \
  "repo:dionm/<repo>:environment:staging" \
  "repo:dionm/<repo>:environment:production"; do
  name=$(echo $subject | sed 's|[:/\*]|-|g' | tr '[:upper:]' '[:lower:]')
  az ad app federated-credential create --id $OBJ_ID \
    --parameters "{\"name\":\"$name\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"subject\":\"$subject\",\"audiences\":[\"api://AzureADTokenExchange\"]}"
done
```

3. Set `AZURE_CLIENT_ID` in the repo's GitHub secrets.
4. Update the tables above.

---

## Versioning

Callers pin to a tag (e.g. `@v1`). To release a new version:

```bash
git tag v2 && git push origin v2
```

Update the `@v1` reference in each caller workflow to adopt the new version.
