#!/usr/bin/env bash
# terraform -> build/push image -> kustomize render -> kubectl apply
# read this before running it, don't just pipe it to bash
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID to your GCP project}"
: "${IMAGE_TAG:=latest}"

REGION="${REGION:-us-central1}"
CLUSTER_NAME="${CLUSTER_NAME:-nexus-cluster}"

cd "$(dirname "$0")/.."

echo "==> 1. Terraform: create GCS bucket + GKE cluster + Artifact Registry repo"
pushd terraform >/dev/null
terraform init
terraform apply -var="project_id=${PROJECT_ID}" -var="bucket_name=${PROJECT_ID}-nexus-blobstore"
GSA_EMAIL=$(terraform output -raw gcs_service_account_email)
CLUSTER_LOCATION=$(terraform output -raw cluster_location)
AR_REPO=$(terraform output -raw artifact_registry_repo)
popd >/dev/null

IMAGE="${AR_REPO}/nexus3-gcs:${IMAGE_TAG}"

echo "==> 2. Build and push the custom Nexus image"
# gcr.io is shut down, we're on Artifact Registry - needs this one-time docker auth
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
docker build -t "${IMAGE}" .
docker push "${IMAGE}"

echo "==> 3. Point kubectl at the new cluster"
# needs the gcloud CLI - https://cloud.google.com/sdk/docs/install
gcloud container clusters get-credentials "${CLUSTER_NAME}" --zone "${CLUSTER_LOCATION}" --project "${PROJECT_ID}"

echo "==> 4. Render manifests with the real image + service account, apply"
# kubectl's own kustomize renderer is enough, don't need the standalone binary
kubectl kustomize k8s/overlays/test \
  | sed -e "s#REPLACE_WITH_IMAGE#${IMAGE}#" -e "s#REPLACE_WITH_GSA_EMAIL#${GSA_EMAIL}#" \
  | kubectl apply -f -

echo "==> Done. Watch rollout with: kubectl -n nexus-test rollout status deploy/nexus"
echo "==> Then get the external IP with: kubectl -n nexus-test get svc nexus"
echo "==> Finally, log into Nexus and create the blob store by hand (see README:"
echo "    Admin > Repository > Blob Stores > Create blob store > Google Cloud Storage,"
echo "    bucket=${PROJECT_ID}-nexus-blobstore, project=${PROJECT_ID})."
