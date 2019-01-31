/*
 * Input variables.
 */

variable "domain_name" {
  description = "Root domain name"
  type        = "string"
}

variable "gcs_access_key" {
  description = "GCS access key"
  type        = "string"
}

variable "gcs_secret_key" {
  description = "GCS secret key"
  type        = "string"
}

variable "google_application_credentials" {
  description = "Path to GCE JSON key file (used in k8s secrets for accessing GCE resources). Normally equals to GOOGLE_APPLICATION_CREDENTIALS env var value."
  type        = "string"
}

variable "google_project_id" {
  description = "GCE project ID"
  type        = "string"
}

variable "location" {
  description = "Location to create resources in"
  default     = "US"
  type        = "string"
}

variable "region" {
  default     = "us-central1"
  description = "Region to create resources in"
  type        = "string"
}

/*
 * Terraform providers.
 */

provider "google" {
  version = "~> 1.20"

  project = "${var.google_project_id}"
  region  = "${var.region}"
}

provider "helm" {
  version = "~> 0.7"
}

provider "kubernetes" {
  version = "~> 1.5"
}

provider "random" {
  version = "~> 2.0"
}

/*
 * GCS remote storage for storing Terraform state.
 */

terraform {
  backend "gcs" {}
}

/*
 * Terraform resources.
 */

resource "kubernetes_namespace" "gitlab" {
  metadata {
    name = "gitlab"
  }
}

# GCS resources.
resource "google_storage_bucket" "gitlab_registry" {
  location = "${var.location}"
  name     = "${var.google_project_id}-gitlab-registry"
}

resource "kubernetes_secret" "gitlab_registry_storage" {
  metadata {
    name      = "gitlab-registry-storage"
    namespace = "${kubernetes_namespace.gitlab.metadata.0.name}"
  }

  data {
    registryStorage = <<EOF
gcs:
  bucket: ${google_storage_bucket.gitlab_registry.name}
  keyfile: /etc/docker/registry/storage/gcs.json
EOF

    gcs.json = "${file("${var.google_application_credentials}")}"
  }
}

resource "google_storage_bucket" "gitlab_lfs" {
  location = "${var.location}"
  name     = "${var.google_project_id}-gitlab-lfs"
}

resource "google_storage_bucket" "gitlab_artifacts" {
  location = "${var.location}"
  name     = "${var.google_project_id}-gitlab-artifacts"
}

resource "google_storage_bucket" "gitlab_uploads" {
  location = "${var.location}"
  name     = "${var.google_project_id}-gitlab-uploads"
}

resource "google_storage_bucket" "gitlab_packages" {
  location = "${var.location}"
  name     = "${var.google_project_id}-gitlab-packages"
}

resource "google_storage_bucket" "gitlab_pseudonymizer" {
  location = "${var.location}"
  name     = "${var.google_project_id}-gitlab-pseudonymizer"
}

resource "google_storage_bucket" "gitlab_runner_cache" {
  location = "${var.location}"
  name     = "${var.google_project_id}-gitlab-runner-cache"
}

resource "kubernetes_secret" "gitlab_storage" {
  metadata {
    name      = "gitlab-storage"
    namespace = "${kubernetes_namespace.gitlab.metadata.0.name}"
  }

  data {
    connection = <<EOF
provider: Google
google_project: ${var.google_project_id}
google_client_email: terraform-sa@${var.google_project_id}.iam.gserviceaccount.com

google_json_key_string: |
  ${indent(2, file("${var.google_application_credentials}"))}
EOF
  }
}

resource "google_storage_bucket" "gitlab_backups" {
  location = "${var.location}"
  name     = "${var.google_project_id}-gitlab-backups"
}

resource "google_storage_bucket" "gitlab_tmp" {
  location = "${var.location}"
  name     = "${var.google_project_id}-gitlab-tmp"
}

resource "kubernetes_secret" "gitlab_s3cfg" {
  metadata {
    name      = "gitlab-s3cfg"
    namespace = "${kubernetes_namespace.gitlab.metadata.0.name}"
  }

  data {
    config = <<EOF
[default]
host_base = minio.${var.domain_name}
host_bucket = minio.${var.domain_name}
bucket_location = us-central-1
use_https = True

access_key = ${random_string.minio_access_key.result}
secret_key = ${random_string.minio_secret_key.result}

signature_v2 = False
EOF
  }
}

resource "random_string" "minio_access_key" {
  length  = 16
  special = false
}

resource "random_string" "minio_secret_key" {
  length  = 32
  special = true
}

resource "kubernetes_secret" "minio_secret" {
  metadata {
    name      = "minio-secret"
    namespace = "${kubernetes_namespace.gitlab.metadata.0.name}"
  }

  data {
    accesskey = "${random_string.minio_access_key.result}"
    secretkey = "${random_string.minio_secret_key.result}"
  }
}

# Minio module.
module "minio" {
  source = "modules/minio"

  access_key                     = "${random_string.minio_access_key.result}"
  domain_name                    = "minio.${var.domain_name}"
  google_application_credentials = "${var.google_application_credentials}"
  google_project_id              = "${var.google_project_id}"
  namespace                      = "${kubernetes_namespace.gitlab.metadata.0.name}"
  secret_key                     = "${random_string.minio_secret_key.result}"
}

# GitLab Helm repository.
resource "helm_repository" "gitlab" {
  name = "gitlab"
  url  = "https://charts.gitlab.io/"
}

# GitLab Helm chart.
resource "helm_release" "gitlab" {
  chart         = "gitlab/gitlab"
  name          = "gitlab"
  namespace     = "${kubernetes_namespace.gitlab.metadata.0.name}"
  repository    = "${helm_repository.gitlab.metadata.0.name}"
  force_update  = true
  recreate_pods = true
  reuse_values  = true

  values = [<<EOF
certmanager:
  install: false

gitaly:
  persistence:
    matchLabels:
      app: gitaly
      release: gitlab

gitlab:
  gitlab-shell:
    minReplicas: 1
  sidekiq:
    minReplicas: 1
    resources:
      limits:
        memory: 1.5G
      requests:
        cpu: 50m
        memory: 625M
  task-runner:
    backups:
      objectStorage:
        config:
          key: config
          secret: ${kubernetes_secret.gitlab_s3cfg.metadata.0.name}
  unicorn:
    ingress:
      tls:
        enabled: true
    minReplicas: 1
    resources:
      limits:
       memory: 1.5G
      requests:
        cpu: 100m
        memory: 900M
    workhorse:
      resources:
        limits:
          memory: 100M
        requests:
          cpu: 10m
          memory: 10M

gitlab-runner:
  builds:
    cpuLimit: 500m
    memoryLimit: 786Mi
    cpuRequests: 150m
    memoryRequests: 256Mi
  image: gitlab/gitlab-runner:alpine-bleeding
  install: true
  rbac:
    create: true
    clusterWideAccess: true
  runners:
    cache:
      cacheType: s3
      s3BucketName: ${google_storage_bucket.gitlab_runner_cache.name}
      s3ServerAddress: https://minio.${var.domain_name}
      cacheShared: true
      s3BucketLocation: minio
      s3CachePath: gitlab-runner
      s3CacheInsecure: false
      secretName: ${kubernetes_secret.minio_secret.metadata.0.name}
    locked: false
    privileged: true

global:
  appConfig:
    email:
      from: "gitlab@maxtopmedia.com"
      display_name: GitLab
      reply_to: "noreply@maxtopmedia.com"
      subject_suffix: ""
    enableUsagePing: false
    lfs:
      bucket: ${google_storage_bucket.gitlab_lfs.name}
      connection:
        secret: ${kubernetes_secret.gitlab_storage.metadata.0.name}
        key: connection
    artifacts:
      bucket: ${google_storage_bucket.gitlab_artifacts.name}
      connection:
        secret: ${kubernetes_secret.gitlab_storage.metadata.0.name}
        key: connection
    uploads:
      bucket: ${google_storage_bucket.gitlab_uploads.name}
      connection:
        secret: ${kubernetes_secret.gitlab_storage.metadata.0.name}
        key: connection
    packages:
      bucket: ${google_storage_bucket.gitlab_packages.name}
      connection:
        secret: ${kubernetes_secret.gitlab_storage.metadata.0.name}
        key: connection
    backups:
      bucket: ${google_storage_bucket.gitlab_backups.name}
      tmpBucket: ${google_storage_bucket.gitlab_tmp.name}
    pseudonymizer:
      bucket: ${google_storage_bucket.gitlab_pseudonymizer.name}
      connection:
        secret: ${kubernetes_secret.gitlab_storage.metadata.0.name}
        key: connection
  edition: ce
  hosts:
    domain: ${var.domain_name}
  ingress:
    class: "nginx"
    configureCertmanager: false
    enabled: true
    tls:
      enabled: true
  minio:
    enabled: false
  registry:
    bucket: ${google_storage_bucket.gitlab_registry.name}

nginx-ingress:
  enabled: false

postgresql:
  persistence:
    matchLabels:
      app: postgresql
      release: gitlab
    storageClass: "fast"

prometheus:
  install: false

redis:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi

registry:
  ingress:
    tls:
      enabled: true
  minReplicas: 1
  storage:
    secret: ${kubernetes_secret.gitlab_registry_storage.metadata.0.name}
    key: registryStorage
    extraKey: gcs.json
EOF
  ]
}
