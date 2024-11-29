# main.tf

# =========================
# Provider Configuration
# =========================

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# =========================
# Variable Definitions
# =========================

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP Zone"
  type        = string
  default     = "us-central1-a"
}

variable "repo_name" {
  description = "Repository name for Cloud Build trigger in the format owner/repo"
  type        = string
}

variable "branch_pattern" {
  description = "Branch pattern to trigger the build"
  type        = string
  default     = "^main$"
}

# =========================
# VPC and Subnets
# =========================

# VPC Network
resource "google_compute_network" "khan_vpc" {
  name                    = "khan-vpc"
  auto_create_subnetworks = false
}

# Public Subnet
resource "google_compute_subnetwork" "khan_public_subnet" {
  name                    = "khan-public-subnet"
  ip_cidr_range           = "10.0.1.0/24"
  region                  = var.region
  network                 = google_compute_network.khan_vpc.id
}

# Private Subnet
resource "google_compute_subnetwork" "khan_private_subnet" {
  name          = "khan-private-subnet"
  ip_cidr_range = "10.0.2.0/24"
  region        = var.region
  network       = google_compute_network.khan_vpc.id
}

# =========================
# Firewall Rules
# =========================

# Firewall Rule to allow HTTP traffic on port 5000
resource "google_compute_firewall" "khan_allow_http" {
  name    = "khan-allow-http"
  network = google_compute_network.khan_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["5000"]
  }

  source_ranges = ["0.0.0.0/0"]
}

# =========================
# Service Account
# =========================

# Service Account for Compute Engine Instance
resource "google_service_account" "khan_compute_sa" {
  account_id   = "khan-compute-sa"
  display_name = "Service Account for Khan Compute Engine Instance"
}

# Grant necessary roles to the service account
resource "google_project_iam_member" "khan_compute_sa_roles" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.khan_compute_sa.email}"
}

resource "google_project_iam_member" "khan_compute_sa_storage" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.khan_compute_sa.email}"
}

# =========================
# Compute Engine Instance
# =========================

# Compute Engine Instance running the Flask container
resource "google_compute_instance" "khan_flask_instance" {
  name         = "khan-flask-instance"
  machine_type = "e2-medium"
  zone         = var.zone
  tags         = ["http-server"]

  boot_disk {
    initialize_params {
      image = "cos-cloud/global/images/family/cos-stable"  # Container-Optimized OS
      size  = 10
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.khan_public_subnet.name

    access_config {
      # Ephemeral public IP
    }
  }

  service_account {
    email  = google_service_account.khan_compute_sa.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    gce-container-declaration = jsonencode({
      spec = {
        containers = [
          {
            name  = "khan-flask-container"
            image = "gcr.io/${var.project_id}/khan-flask-app:latest"
            ports = [
              {
                name          = "http"
                containerPort = 5000
              }
            ]
          }
        ]
        restartPolicy = "Always"
      }
    })
    google-logging-enabled    = "true"
    google-monitoring-enabled = "true"
  }

  # Optional: Enable SSH access
  metadata_startup_script = <<-EOF
    #!/bin/bash
    sudo mkdir -p /var/log/flask
    sudo chmod 755 /var/log/flask
  EOF
}

# =========================
# Cloud Build Trigger
# =========================

# Cloud Build Trigger for Continuous Delivery
resource "google_cloudbuild_trigger" "khan_cloudbuild_trigger" {
  name = "khan-cloudbuild-trigger"

  github {
    owner = split("/", var.repo_name)[0]
    name  = split("/", var.repo_name)[1]

    push {
      branch = var.branch_pattern
    }
  }

  build {
    step {
      name = "gcr.io/cloud-builders/docker"
      args = ["build", "-t", "gcr.io/${var.project_id}/khan-flask-app:$SHORT_SHA", "."]
    }
    step {
      name = "gcr.io/cloud-builders/docker"
      args = ["push", "gcr.io/${var.project_id}/khan-flask-app:$SHORT_SHA"]
    }
    step {
      name = "gcr.io/cloud-builders/gcloud"
      args = [
        "compute", "instances", "update-container", google_compute_instance.khan_flask_instance.name,
        "--zone", var.zone,
        "--container-image", "gcr.io/${var.project_id}/khan-flask-app:$SHORT_SHA"
      ]
    }

    images = [
      "gcr.io/${var.project_id}/khan-flask-app:$SHORT_SHA"
    ]

  }
}

# =========================
# Outputs
# =========================

output "instance_ip" {
  description = "Public IP of the Flask application instance"
  value       = google_compute_instance.khan_flask_instance.network_interface[0].access_config[0].nat_ip
}
