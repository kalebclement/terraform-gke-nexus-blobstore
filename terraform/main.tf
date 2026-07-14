# --- APIs we need enabled ---

resource "google_project_service" "container" {
  project            = var.project_id
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "storage" {
  project            = var.project_id
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iam" {
  project            = var.project_id
  service            = "iam.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "artifactregistry" {
  project            = var.project_id
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "firestore" {
  project            = var.project_id
  service            = "firestore.googleapis.com"
  disable_on_destroy = false
}

# plugin uses Datastore to track soft-deleted blobs - has to be named
# "(default)", DATASTORE_MODE since the plugin's client lib needs that API

resource "google_firestore_database" "default" {
  project     = var.project_id
  name        = "(default)"
  location_id = var.region
  type        = "DATASTORE_MODE"

  depends_on = [google_project_service.firestore]
}

# gcr.io is dead (shut down 2025), so the image goes to Artifact Registry

resource "google_artifact_registry_repository" "nexus3_gcs" {
  project       = var.project_id
  location      = var.region
  repository_id = "nexus3-gcs"
  format        = "DOCKER"

  depends_on = [google_project_service.artifactregistry]
}

data "google_project" "current" {
  project_id = var.project_id
}

# our node pool has no service_account set, so nodes run as the default
# Compute Engine SA - which no longer gets auto-granted Editor on new
# projects, so it can't pull images without this grant
resource "google_artifact_registry_repository_iam_member" "gke_node_pull" {
  project    = var.project_id
  location   = google_artifact_registry_repository.nexus3_gcs.location
  repository = google_artifact_registry_repository.nexus3_gcs.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

# --- the actual blob store bucket ---

resource "google_storage_bucket" "nexus_blobstore" {
  name                        = var.bucket_name
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = false

  labels = {
    managed-by = "terraform"
  }

  versioning {
    enabled = false
  }

  depends_on = [google_project_service.storage]
}

# --- SA Nexus runs as, bound to the KSA via Workload Identity ---

resource "google_service_account" "nexus_gcs" {
  project      = var.project_id
  account_id   = "nexus-gcs-blobstore"
  display_name = "Nexus GCS blob store"

  depends_on = [google_project_service.iam]
}

resource "google_storage_bucket_iam_member" "nexus_gcs_writer" {
  bucket = google_storage_bucket.nexus_blobstore.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.nexus_gcs.email}"
}

# objectAdmin doesn't cover storage.buckets.get, which the plugin needs to
# confirm the bucket exists - legacyBucketReader adds just that
resource "google_storage_bucket_iam_member" "nexus_gcs_bucket_reader" {
  bucket = google_storage_bucket.nexus_blobstore.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.nexus_gcs.email}"
}

# Datastore IAM is project-scoped only, no per-database roles like the bucket has
resource "google_project_iam_member" "nexus_gcs_datastore_user" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.nexus_gcs.email}"
}

resource "google_service_account_iam_member" "workload_identity_binding" {
  service_account_id = google_service_account.nexus_gcs.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/${var.ksa_name}]"

  # WI pool doesn't exist until the cluster does - without this Terraform
  # may run them in parallel and fail with "Identity Pool does not exist"
  depends_on = [google_container_cluster.primary]
}

# --- the cluster itself ---

resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  project  = var.project_id
  location = var.zone

  remove_default_node_pool = true
  initial_node_count       = 1

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  depends_on = [google_project_service.container]
}

resource "google_container_node_pool" "primary_nodes" {
  name     = "${var.cluster_name}-pool"
  project  = var.project_id
  location = var.zone
  cluster  = google_container_cluster.primary.name

  node_count = var.node_count

  node_config {
    machine_type = var.node_machine_type
    preemptible  = true

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
