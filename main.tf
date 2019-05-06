/*
 * Input variables.
 */

variable "aws_access_key" {
  description = "AWS access key"
  type        = "string"
}

variable "aws_secret_key" {
  description = "AWS secret key"
  type        = "string"
}

variable "domain_name" {
  description = "Root domain name"
  type        = "string"
}

variable "region" {
  default     = "us-east-1"
  description = "Region to create resources in"
  type        = "string"
}

variable "smtp_password" {
  default     = ""
  description = "SMTP password"
  type        = "string"
}

variable "smtp_settings" {
  description = "GitLab SMTP settings"
  type        = "string"
}

/*
 * Local definitions.
 */

locals {
  prefix = "${replace(var.domain_name, ".", "-")}"
}

/*
 * Terraform providers.
 */

provider "aws" {
  region  = "${var.region}"
  version = "~> 2.8"
}

provider "helm" {
  version = "~> 0.9"
}

provider "kubernetes" {
  version = "~> 1.6"
}

/*
 * S3 remote storage for storing Terraform state.
 */

terraform {
  backend "s3" {}
}

/*
 * Terraform resources.
 */

resource "kubernetes_namespace" "gitlab" {
  metadata {
    name = "gitlab"
  }
}

# S3 bucket resources.
resource "aws_s3_bucket" "gitlab_registry" {
  bucket = "${local.prefix}-gitlab-registry"
}

resource "kubernetes_secret" "gitlab_registry_storage" {
  metadata {
    name      = "gitlab-registry-storage"
    namespace = "${kubernetes_namespace.gitlab.metadata.0.name}"
  }

  data {
    registryStorage = <<EOF
s3:
  bucket: ${aws_s3_bucket.gitlab_registry.bucket}
  accesskey: ${var.aws_access_key}
  secretkey: ${var.aws_secret_key}
  region: ${var.region}
  v4auth: true
EOF
  }
}

resource "kubernetes_secret" "gitlab_runner_cache_secret" {
  metadata {
    name      = "gitlab-runner-cache-secret"
    namespace = "${kubernetes_namespace.gitlab.metadata.0.name}"
  }

  data {
    accesskey = "${var.aws_access_key}"
    secretkey = "${var.aws_secret_key}"
  }
}

resource "kubernetes_secret" "gitlab_smtp_password" {
  metadata {
    name      = "gitlab-smtp-password"
    namespace = "${kubernetes_namespace.gitlab.metadata.0.name}"
  }

  data {
    password = "${var.smtp_password}"
  }
}

resource "aws_s3_bucket" "gitlab_lfs" {
  bucket = "${local.prefix}-gitlab-lfs"
}

resource "aws_s3_bucket" "gitlab_artifacts" {
  bucket = "${local.prefix}-gitlab-artifacts"
}

resource "aws_s3_bucket" "gitlab_uploads" {
  bucket = "${local.prefix}-gitlab-uploads"
}

resource "aws_s3_bucket" "gitlab_packages" {
  bucket = "${local.prefix}-gitlab-packages"
}

resource "aws_s3_bucket" "gitlab_pseudonymizer" {
  bucket = "${local.prefix}-gitlab-pseudonymizer"
}

resource "aws_s3_bucket" "gitlab_runner_cache" {
  bucket = "${local.prefix}-gitlab-runner-cache"
}

resource "kubernetes_secret" "gitlab_storage" {
  metadata {
    name      = "gitlab-storage"
    namespace = "${kubernetes_namespace.gitlab.metadata.0.name}"
  }

  data {
    connection = <<EOF
provider: AWS
region: ${var.region}
aws_access_key_id: ${var.aws_access_key}
aws_secret_access_key: ${var.aws_secret_key}
EOF
  }
}

resource "aws_s3_bucket" "gitlab_backups" {
  bucket = "${local.prefix}-gitlab-backups"
}

resource "aws_s3_bucket" "gitlab_tmp" {
  bucket = "${local.prefix}-gitlab-tmp"
}

resource "kubernetes_secret" "gitlab_s3cfg" {
  metadata {
    name      = "gitlab-s3cfg"
    namespace = "${kubernetes_namespace.gitlab.metadata.0.name}"
  }

  data {
    config = <<EOF
[default]
access_key = ${var.aws_access_key}
secret_key = ${var.aws_secret_key}
bucket_location = ${var.region}
EOF
  }
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

certmanager-issuer:
  email: "admin@instacoins.com"

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
      annotations:
        certmanager.k8s.io/cluster-issuer: letsencrypt
      tls:
        enabled: true
        secretName: gitlab-unicorn-tls
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
  install: true
  rbac:
    create: true
    clusterWideAccess: true
  runners:
    cache:
      cacheType: s3
      s3BucketName: ${aws_s3_bucket.gitlab_runner_cache.bucket}
      cacheShared: true
      s3BucketLocation: ${var.region}
      s3CachePath: gitlab-runner
      s3CacheInsecure: false
      secretName: ${kubernetes_secret.gitlab_runner_cache_secret.metadata.0.name}
    locked: false
    namespace: ${kubernetes_namespace.gitlab.metadata.0.name}
    privileged: true
    tags: "dynamic"

global:
  appConfig:
    email:
      from: "gitlab@${var.domain_name}"
      display_name: GitLab
      reply_to: "noreply@${var.domain_name}"
      subject_suffix: ""
    enableUsagePing: false
    lfs:
      bucket: ${aws_s3_bucket.gitlab_lfs.bucket}
      connection:
        secret: ${kubernetes_secret.gitlab_storage.metadata.0.name}
        key: connection
    artifacts:
      bucket: ${aws_s3_bucket.gitlab_artifacts.bucket}
      connection:
        secret: ${kubernetes_secret.gitlab_storage.metadata.0.name}
        key: connection
    uploads:
      bucket: ${aws_s3_bucket.gitlab_uploads.bucket}
      connection:
        secret: ${kubernetes_secret.gitlab_storage.metadata.0.name}
        key: connection
    packages:
      bucket: ${aws_s3_bucket.gitlab_packages.bucket}
      connection:
        secret: ${kubernetes_secret.gitlab_storage.metadata.0.name}
        key: connection
    backups:
      bucket: ${aws_s3_bucket.gitlab_backups.bucket}
      tmpBucket: ${aws_s3_bucket.gitlab_tmp.bucket}
    pseudonymizer:
      bucket: ${aws_s3_bucket.gitlab_pseudonymizer.bucket}
      connection:
        secret: ${kubernetes_secret.gitlab_storage.metadata.0.name}
        key: connection
  edition: ce
  gitlabVersion: master
  hosts:
    domain: ${var.domain_name}
  imagePullPolicy: Always
  ingress:
    configureCertmanager: true
    enabled: true
    tls:
      enabled: true
  minio:
    enabled: false
  registry:
    bucket: ${aws_s3_bucket.gitlab_registry.bucket}
  smtp:
    ${indent(4, var.smtp_settings)}
    password:
      secret: ${kubernetes_secret.gitlab_smtp_password.metadata.0.name}

nginx-ingress:
  enabled: true
  tcpExternalConfig: "true"
  controller:
    config:
      hsts-include-subdomains: "false"
      server-name-hash-bucket-size: "256"
      enable-vts-status: "true"
      use-http2: "false"
      ssl-ciphers: "ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA:ECDHE-RSA-AES128-SHA:AES256-GCM-SHA384:AES128-GCM-SHA256:AES256-SHA256:AES128-SHA256:AES256-SHA:AES128-SHA:!aNULL:!eNULL:!EXPORT:!DES:!MD5:!PSK:!RC4"
      ssl-protocols: "TLSv1.1 TLSv1.2"
      server-tokens: "false"
    extraArgs:
      force-namespace-isolation: ""
    service:
      externalTrafficPolicy: "Local"
    resources:
      requests:
        cpu: 100m
        memory: 100Mi
    publishService:
      enabled: true
    replicaCount: 3
    minAvailable: 2
    scope:
      enabled: true
    stats:
      enabled: true
    metrics:
      enabled: true
      service:
        annotations:
          prometheus.io/scrape: "true"
          prometheus.io/port: "10254"
  defaultBackend:
    minAvailable: 1
    replicaCount: 2
    resources:
      requests:
        cpu: 5m
        memory: 5Mi
  rbac:
    create: true
  serviceAccount:
    create: true

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
    annotations:
      certmanager.k8s.io/cluster-issuer: letsencrypt
    tls:
      enabled: true
      secretName: gitlab-registry-tls
  minReplicas: 1
  storage:
    secret: ${kubernetes_secret.gitlab_registry_storage.metadata.0.name}
    key: registryStorage
EOF
  ]
}
