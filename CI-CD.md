# 5. Continuous integration (theoretical)

Goal: when this repo changes (e.g. bumping the Nexus/plugin version in the
`Dockerfile`), a test environment redeploys automatically.

**Pipeline: Cloud Build, triggered on push, in three stages.**

1. **Trigger** - a Cloud Build trigger (or GitHub Actions workflow) watches
   the repo's main branch. Any push that touches `Dockerfile`, `k8s/**`, or
   `terraform/**` fires the pipeline. (GitHub Actions works equally well
   here; Cloud Build is a natural fit since everything already lives in
   GCP.)

2. **Build & push** - build the image from the `Dockerfile`, tag it with the
   commit SHA (not `latest`, so every deploy is traceable to a commit and
   rollback is just re-applying an older tag), push to Artifact Registry.

3. **Deploy to test** - run `kustomize edit set image ...=<new tag>` against
   `k8s/overlays/test`, then `kubectl apply -k k8s/overlays/test` against the
   test GKE cluster. Cloud Build authenticates via a service account with
   `roles/container.developer` scoped to just that cluster/namespace.

Infra changes (`terraform/**`) go through a separate `terraform plan` step
that posts the plan as a PR comment for review - the review on the PR
*is* the approval gate. `terraform apply` then runs automatically once
that reviewed change actually merges to main, immediately before the
app deploy, rather than requiring a separate manual step after merge too.

**Promotion beyond test:** the same pipeline, parameterized by overlay
(`k8s/overlays/staging`, `k8s/overlays/prod`), triggered by a git tag or
merge to a `release` branch instead of every push to main - so test gets
continuous deploys, and prod gets an explicit, auditable promotion step.

**If preferred over a push-triggered pipeline:** a GitOps model (Argo CD /
Flux) watching the `k8s/` directory and reconciling the cluster to match
it - the CI pipeline's job then shrinks to just building the image and
bumping the tag in `k8s/overlays/test`, and the GitOps controller handles
the actual `kubectl apply`. This is worth it once there's more than one
environment/cluster to keep in sync; for a single test cluster the simpler
push-triggered pipeline above is enough.

The description above is implemented for real in `.github/workflows/`, as
a four-step flow:

1. **Open a PR** touching `Dockerfile`, `k8s/**`, or `terraform/**`.
2. **`pr-checks.yml` runs** - `terraform plan` (posted as a PR comment, so
   the infra diff is visible in review before merge) plus a build/render
   sanity check (`docker build` without pushing, `kubectl kustomize` on
   the test overlay) so a broken Dockerfile or malformed manifest fails
   the PR instead of the merge.
3. **PR merges to main.**
4. **`deploy.yml` runs** - `terraform apply -auto-approve` first (so an
   infra change and an app change landing in the same merge both take
   effect together), then builds/pushes the image tagged with the commit
   SHA and applies `k8s/overlays/test` to the live cluster.

The PR's plan comment is the review gate; merging is treated as approval
for both the infra apply and the app deploy, so nothing further blocks
either one after that point.

**Authentication uses Workload Identity Federation, not a service account
JSON key in GitHub Secrets** - the same "no long-lived credential" pattern
this repo already uses for the GKE pod's access to GCS
(`terraform/main.tf`). GitHub mints a short-lived OIDC token per workflow
run; `terraform/github_actions.tf` sets up a Workload Identity Pool that
exchanges that token for GCP credentials, scoped to exactly one GitHub
repo via `attribute_condition`.

**One-time setup before these workflows will run** (chicken-and-egg: the
thing that lets GitHub Actions authenticate to GCP has to be created by a
human first):

1. `terraform apply` (as already required for the rest of this repo) also
   now creates the Workload Identity Pool/Provider and a dedicated
   `github-actions-ci` service account - but only if you pass
   `-var="github_repo=<owner>/<repo>"` matching wherever this gets pushed.
2. Read the two new outputs:
   ```bash
   terraform output -raw github_actions_workload_identity_provider
   terraform output -raw github_actions_service_account
   ```
3. In the GitHub repo: **Settings -> Secrets and variables -> Actions ->
   Variables**, add:
   - `WIF_PROVIDER` = the first output above
   - `WIF_SERVICE_ACCOUNT` = the second output above
   - `GCP_PROJECT`, `GCP_REGION` (`us-central1`), `GKE_CLUSTER`
     (`nexus-cluster`), `GKE_ZONE` (`us-central1-a`), `GSA_EMAIL` (the
     `gcs_service_account_email` output), `GCS_BUCKET_NAME`

Without that setup, both workflows will fail at the `auth` step with no
credentials to assume - expected for anyone forking this repo without
also owning the underlying GCP project.
