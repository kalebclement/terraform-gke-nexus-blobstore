output "bucket_name" {
  value = google_storage_bucket.nexus_blobstore.name
}

output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "cluster_location" {
  value = google_container_cluster.primary.location
}

output "cluster_endpoint" {
  value     = google_container_cluster.primary.endpoint
  sensitive = true
}

output "gcs_service_account_email" {
  description = "Put this into k8s/base/serviceaccount.yaml's iam.gke.io/gcp-service-account annotation"
  value       = google_service_account.nexus_gcs.email
}

output "artifact_registry_repo" {
  description = "docker tag/push target: <this>/nexus3-gcs:<tag>"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.nexus3_gcs.repository_id}"
}

output "github_actions_workload_identity_provider" {
  description = "Set as the GitHub repo variable WIF_PROVIDER (Settings -> Secrets and variables -> Actions -> Variables)"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "github_actions_service_account" {
  description = "Set as the GitHub repo variable WIF_SERVICE_ACCOUNT"
  value       = google_service_account.github_actions.email
}
