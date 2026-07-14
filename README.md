# Nexus on GKE with a GCS blob store — SRE exercise

Runs Sonatype Nexus 3 on Google Kubernetes Engine, storing uploaded
artifacts in a Cloud Storage bucket via the
[`nexus-blobstore-google-cloud`](https://github.com/sonatype-nexus-community/nexus-blobstore-google-cloud)
plugin.

```
.
├── Dockerfile                 # 1. custom Nexus image with the GCS plugin baked in
├── k8s/                       # 2. Service, PVC, Deployment (Kustomize base + test overlay)
├── terraform/                 # 3. GCS bucket + GKE cluster (1 preemptible n1-standard-1 node)
├── scripts/deploy.sh          # 4. ties 1-3 together end to end
└── CI-CD.md                   # 5. CI/CD
```

## 1. Custom container

`Dockerfile` starts `FROM sonatype/nexus3:3.64.0` and adds the plugin's
`.kar` bundle straight into `/opt/sonatype/nexus/deploy`, which Karaf scans
and installs on startup — no manual feature registration needed.

The community plugin repo was archived in Nov 2024; its last release
(`0.61.0`) targets Nexus `3.64.0`, so that's the pinned combination. Bump
`NEXUS_VERSION`/`PLUGIN_VERSION` together if you validate a newer pairing
(unlikely, since the plugin is no longer maintained).

Build it yourself:

```bash
docker build -t nexus3-gcs:test .
```

(Already verified — builds clean.)

## 2. Kubernetes configs

`k8s/base` (Kustomize):

- `namespace.yaml`, `serviceaccount.yaml` — a KSA annotated for **Workload
  Identity**, so the pod authenticates to GCS as a real GCP service account
  with no JSON key file to manage or rotate.
- `pvc.yaml` — 10Gi for Nexus's own `/nexus-data` (DB, config, search index,
  caches). Uploaded artifacts go to GCS, not this disk, so it stays small.
- `deployment.yaml` — single replica (`strategy: Recreate`, since one
  ReadWriteOnce volume can't be shared across pods), readiness/liveness
  probes on `/service/rest/v1/status`, resources sized to fit comfortably
  on an `n1-standard-1` node.
- `service.yaml` — `LoadBalancer` exposing port 8081.

`k8s/overlays/test` retargets everything into its own `nexus-test`
namespace (via Kustomize's `namespace:` field, so a future `staging`/`prod`
overlay can't collide with it), tightens resource limits, and is where CI
patches in the real image tag (see `CI-CD.md`).

Render and check it yourself (read-only, touches no cluster):

```bash
kubectl kustomize k8s/overlays/test
```

## 3. GCP resource creation

`terraform/` creates:

- `google_storage_bucket.nexus_blobstore` — the blob store bucket.
- `google_container_cluster.primary` + `google_container_node_pool.primary_nodes`
  — a zonal GKE cluster, default node pool removed, replaced by a single
  **preemptible `n1-standard-1`** node (per the cost constraint), Workload
  Identity enabled.
- `google_service_account.nexus_gcs` — granted `roles/storage.objectAdmin`
  + `roles/storage.legacyBucketReader` on the bucket (object CRUD plus the
  bucket-metadata read the plugin needs to confirm the bucket exists) and
  `roles/datastore.user` at the project level (see below), all bound to the
  in-cluster KSA via `roles/iam.workloadIdentityUser`.
- `google_artifact_registry_repository.nexus3_gcs` — where the custom image
  gets pushed. Container Registry (`gcr.io`) is fully shut down (writes
  disabled since March 2025), so a new project has no choice but Artifact
  Registry. Also grants the GKE node's default Compute Engine service
  account `roles/artifactregistry.reader` on this repo - new projects no
  longer auto-grant that account project Editor, so without this the node
  can't pull the image at all (403 on every pull attempt).
- `google_firestore_database.default` (Datastore mode) — not something the
  assignment asks for, but the GCS blob store plugin uses Cloud Datastore
  internally to track a "deleted blob index" (soft-delete bookkeeping GCS
  itself has no transactional query support for). A fresh project has no
  database until one's explicitly created, so the blob store can't even be
  saved in the Nexus UI without this existing first - discovered by
  actually testing the blob store creation, not from any documentation.

Run yourself (needs `gcloud` authenticated and a real GCP project with
billing enabled — I don't have credentials for your project, so this step
is on you):

```bash
cd terraform
terraform init
terraform apply -var="project_id=<your-project-id>" -var="bucket_name=<globally-unique-name>"
```

## 4. Deploy

`scripts/deploy.sh` chains steps 1-3: `terraform apply` → build/push the
image → `gcloud container clusters get-credentials` → patch the rendered
manifests with the real image and service-account email → `kubectl apply`.
It's meant to be read section by section and run by you, not piped blindly
to `bash` — it touches your GCP project and Docker registry.

```bash
export PROJECT_ID=<your-project-id>
./scripts/deploy.sh
```

**One manual step after the pod is up:** Nexus stores blob store
definitions in its own internal database, not in a file this repo can
ship — so log into the Nexus UI (`admin` / initial password at
`/nexus-data/admin.password` inside the pod) and create the blob store by
hand: **Administration → Repository → Blob Stores → Create blob store →
Google Cloud Storage**, using the bucket name and project ID from the
Terraform output. Then point your repositories (proxy/hosted) at that blob
store.

**Cost / teardown:** this footprint (one preemptible `n1-standard-1` node,
one zonal cluster — which gets the free cluster-management-fee waiver for
the first zonal cluster per billing account — and a near-empty bucket)
runs to a few cents an hour at most. Still, once you've captured your
result, tear it down rather than leaving it running:

```bash
cd terraform
terraform destroy -var="project_id=<your-project-id>" -var="bucket_name=<same-name-you-applied-with>"
```

## 5. Continuous integration

See [`CI-CD.md`](./CI-CD.md).

## Notes / trade-offs

- Single node, `n1-standard-1`, preemptible: as specified, for cost — not a
  production sizing. A preemptible node can be reclaimed at any time, so
  expect the odd Nexus restart; that's an acceptable trade for a
  cost-constrained exercise, not something I'd run production artifact
  storage on.
- Workload Identity over a mounted service-account key: no secret file to
  generate, distribute, or rotate, and it's the currently recommended GKE
  pattern.
- The Workload Identity IAM binding is scoped by namespace + KSA name
  (`terraform/variables.tf`'s `namespace`/`ksa_name`, default `nexus-test`/
  `nexus` to match `k8s/overlays/test`). If you add another overlay (e.g.
  `staging`) with a different `namespace:`, either add a matching
  `google_service_account_iam_member` binding for it or override `-var
  namespace=...` on that environment's `terraform apply` — otherwise the
  pod authenticates as a KSA the GCP service account doesn't trust, and
  GCS writes fail with a permissions error.

_CI/CD pipeline verified end-to-end: PR checks + auto-deploy on merge._
