/*
 * Input variables.
 */

variable "access_key" {
  description = "Minio access key"
  type        = "string"
}

variable "domain_name" {
  description = "Root domain name"
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

variable "namespace" {
  description = "Namespace name"
  type        = "string"
}

variable "secret_key" {
  description = "Minio secret key"
  type        = "string"
}

/*
 * Local definitions.
 */

locals {
  module_path = "${replace(path.module, "\\", "/")}"
}

/*
 * Terraform providers.
 */

provider "local" {
  version = "~> 1.1"
}

provider "null" {
  version = "~> 1.0"
}

provider "template" {
  version = "~> 1.0"
}

/*
 * Terraform resources.
 */

resource "kubernetes_secret" "minio_gcs_credentials" {
  metadata {
    name      = "minio-gcs-credentials"
    namespace = "${var.namespace}"
  }

  data {
    registryStorage = <<EOF
${file("${var.google_application_credentials}")}
EOF
  }
}

resource "kubernetes_deployment" "minio" {
  metadata {
    name      = "minio"
    namespace = "${var.namespace}"

    labels {
      app = "minio"
    }
  }

  spec {
    selector {
      match_labels {
        app = "minio"
      }
    }

    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels {
          app = "minio"
        }
      }

      spec {
        container {
          image = "minio/minio:RELEASE.2019-01-10T00-21-20Z"
          name  = "minio"

          args = ["gateway", "gcs", "${var.google_project_id}"]

          env {
            name  = "MINIO_ACCESS_KEY"
            value = "${var.access_key}"
          }

          env {
            name  = "MINIO_SECRET_KEY"
            value = "${var.secret_key}"
          }

          env {
            name  = "GOOGLE_APPLICATION_CREDENTIALS"
            value = "/etc/credentials/application_default_credentials.json"
          }

          port {
            container_port = 9000
            name           = "http-port"
          }

          volume_mount {
            name       = "${kubernetes_secret.minio_gcs_credentials.metadata.0.name}"
            mount_path = "/etc/credentials"
            read_only  = true
          }
        }

        volume {
          name = "${kubernetes_secret.minio_gcs_credentials.metadata.0.name}"

          secret {
            secret_name = "${kubernetes_secret.minio_gcs_credentials.metadata.0.name}"

            items {
              key  = "registryStorage"
              path = "application_default_credentials.json"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "minio" {
  metadata {
    name      = "minio"
    namespace = "${var.namespace}"

    labels {
      app = "minio"
    }
  }

  spec {
    type = "ClusterIP"

    port {
      name        = "http-port"
      protocol    = "TCP"
      port        = 9000
      target_port = 9000
    }

    selector {
      app = "minio"
    }
  }
}

# Ingress resource.
data "template_file" "ingress" {
  template = "${file("${local.module_path}/templates/ingress.tpl")}"

  vars {
    domain_name = "${var.domain_name}"
    namespace   = "${var.namespace}"
  }
}

resource "local_file" "ingress" {
  content  = "${data.template_file.ingress.rendered}"
  filename = ".terraform/ingress.yaml"
}

resource "null_resource" "create_ingress" {
  depends_on = ["kubernetes_service.minio", "local_file.ingress"]

  provisioner "local-exec" {
    command     = "kubectl apply -f ingress.yaml"
    working_dir = ".terraform"
  }

  triggers {
    config_rendered = "${data.template_file.ingress.rendered}"
  }
}
