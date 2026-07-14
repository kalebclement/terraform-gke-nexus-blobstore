terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  # shared state so local runs and CI see the same world - the bucket
  # itself has to exist before this works, and backend blocks can't use
  # variables, so it's created manually (see README) not through this config
  backend "gcs" {
    bucket = "kaleb-hands-on-project-502317-tfstate"
    prefix = "terraform/state"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
