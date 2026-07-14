variable "project_id" {
  description = "GCP project ID to deploy into"
  type        = string
}

variable "region" {
  description = "Region for the GCS bucket. us-central1 keeps small buckets inside the Always Free Cloud Storage allowance."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone for the (zonal) GKE cluster and its node pool - kept in the same region as the bucket to avoid cross-region traffic."
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
  default     = "nexus-cluster"
}

variable "bucket_name" {
  description = "Globally-unique name for the GCS bucket used as the Nexus blob store"
  type        = string
}

variable "node_machine_type" {
  description = "Machine type for the single node pool"
  type        = string
  default     = "n1-standard-1"
}

variable "node_count" {
  description = "Number of nodes in the pool (kept at 1 to minimize cost)"
  type        = number
  default     = 1
}

variable "namespace" {
  description = "Kubernetes namespace Nexus runs in - used to scope the Workload Identity binding. Must match the `namespace:` field in whichever k8s/overlays/* is actually applied (the test overlay uses nexus-test)."
  type        = string
  default     = "nexus-test"
}

variable "ksa_name" {
  description = "Kubernetes ServiceAccount name Nexus runs as - used to scope the Workload Identity binding"
  type        = string
  default     = "nexus"
}

variable "github_repo" {
  description = "GitHub repo allowed to assume the CI service account via Workload Identity Federation, as 'owner/name' (e.g. kalebclement19/cloudmile). Required for the GitHub Actions workflows under .github/workflows/ to authenticate to GCP."
  type        = string
}
