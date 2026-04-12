# dionm/workflows

Shared GitHub Actions reusable workflows for Azure App Service container deployments.

## `azure-app-service-deploy.yml`

Builds an app into a Docker image, pushes to ACR, and deploys to Azure App Service.
Supports both Node.js-built sites (Gatsby, etc.) and plain static HTML sites.

### Tag strategy

| Trigger | Image tag | Environment |
|---|---|---|
| Push to `develop` | `staging-<sha7>` | staging |
| Push to `main` | `production-<sha7>` | production |
| `v*.*.*` tag | `v<semver>` | production |
| PR | `pr-<number>` | (build only) |

### Usage

```yaml
jobs:
  deploy:
    uses: dionm/workflows/.github/workflows/azure-app-service-deploy.yml@v1
    with:
      image_name: my-app          # required
      service_name: my-service    # required
      run_build: true             # false for plain static HTML sites
    secrets: inherit
```

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `image_name` | yes | | ACR image name (e.g. `spectrum-app`) |
| `service_name` | yes | | Passed as `SERVICE_NAME` Dockerfile build-arg |
| `node_version` | no | `20` | Node.js version (ignored when `run_build: false`) |
| `run_build` | no | `true` | Run `npm install` + build before Docker. Set `false` for static HTML sites |
| `build_command` | no | `npm run build` | Build command (ignored when `run_build: false`) |
| `dockerfile` | no | `Dockerfile.hybrid` | Dockerfile for CI/CD builds |
| `health_check_path` | no | `/health` | HTTP path polled after each deploy |
| `gatsby_validation` | no | `false` | Fail if deprecated `gatsby-image` import found |
| `environment` | no | `''` | Manual override: `staging` or `production` |
| `skip_tests` | no | `false` | Skip the test job |

### Required secrets

Pass via `secrets: inherit` or explicitly. All must be set in the calling repo.

| Secret | Shared/per-repo |
|---|---|
| `AZURE_CLIENT_ID` | shared |
| `AZURE_TENANT_ID` | shared |
| `AZURE_SUBSCRIPTION_ID` | shared |
| `ACR_LOGIN_SERVER` | shared |
| `RESOURCE_GROUP_STAGING` | per-repo |
| `RESOURCE_GROUP_PRODUCTION` | per-repo |
| `WEBAPP_NAME_STAGING` | per-repo |
| `WEBAPP_NAME_PRODUCTION` | per-repo |
| `TEAMS_WEBHOOK_URL` | optional |

## Versioning

Callers pin to a tag (e.g. `@v1`). To release a new version:

```bash
git tag v2 && git push origin v2
```

Update the `@v1` reference in each caller workflow to adopt the new version.
