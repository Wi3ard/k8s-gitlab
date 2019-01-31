# GitLab Terraform configuration for Kubernetes

- [GitLab Terraform configuration for Kubernetes](#gitlab-terraform-configuration-for-kubernetes)
  - [Terraform initialization](#terraform-initialization)
  - [Installation](#installation)
  - [Upgrade](#upgrade)
  - [Managing persistent volumes](#managing-persistent-volumes)
    - [Change reclaim policy for application volumes](#change-reclaim-policy-for-application-volumes)
    - [Delete persistent volumes](#delete-persistent-volumes)
  - [Troubleshooting](#troubleshooting)

Terraform configuration for deploying GitLab in a Kubernetes cluster

## Terraform initialization

Copy [terraform.tfvars.example](terraform.tfvars.example) file to `terraform.tfvars` and set input variables values as per your needs.

GitLab backup/restore functionality requires an S3 compatible bucket for storing data. As Google Cloud Storage does provide an S3 interface you could use it, but first you need to generate an access/secret key pair. Those keys are called "interoperable keys" or "migration keys".

In order to create an access/secret key pair to access your Google cloud storage bucket:

1. Go to [GCS Settings](https://console.cloud.google.com/storage/settings).
1. Select the "Interoperability" tab.
1. If you haven't enabled it already, click on "Interoperable Access".
1. Now you should see an empty list and a "Create new Key" button.
1. Click on the button in order to create an access/secret keypair.

Specify those keys in `gcs_access_key` and `gcs_secret_key` input variables in `terraform.tfvars` file.

> **IMPORTANT**: Those keys doesn't belong to the google project but your own account, which you are using to login to the google cloud console.

Next initialize Terraform with `init` command:

```shell
terraform init -backend-config "bucket=$BUCKET_NAME" -backend-config "prefix=apps/gitlab" -backend-config "region=$REGION"
```

- `$REGION` should be replaced with a region name.
- `$BUCKET_NAME` should be replaced with a GCS Terraform state storage bucket name.

## Installation

To apply Terraform plan, run:

```shell
terraform apply
```

## Upgrade

In order to upgrade installation, run:

```shell
$ terraform taint helm_release.gitlab
The resource helm_release.gitlab in the module root has been marked as tainted!

$ terraform apply
```

> **IMPORTANT**: You need to make sure that you changed the `reclaimPolicy` for persistent volumes from `Delete` to `Retain` as explained below, otherwise you will experience a data loss.

## Managing persistent volumes

Some of the included services require persistent storage, configured through Persistent Volumes that specify which disks your cluster has access to.

Storage changes after installation need to be manually handled by your cluster administrators. Automated management of these volumes after installation is not handled by the deployment scripts.

> **IMPORTANT**: you may experience a total data loss if these changes are not applied properly. Specifically, if you don't change the default `Delete` [reclaimPolicy](https://kubernetes.io/docs/concepts/storage/storage-classes/#reclaim-policy) for [PersistentVolumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#persistent-volumes) to `Retain`, the inderlying [Google Persistent Disk](https://cloud.google.com/compute/docs/disks/) will be completely destroyed by GCE upon destruction of a Kubernetes application stack.

### Change reclaim policy for application volumes

Find the volumes/claims that are being used, and change the `reclaimPolicy` for each from `Delete` to `Retain`:

```shell
$ kubectl get pv | grep gitlab
pvc-3acde8a6-1823-11e9-ad5f-42010a80029a   8Gi        RWO            Retain           Released   gitlab/gitlab-postgresql           standard                 5h
pvc-3b7da7c0-1823-11e9-ad5f-42010a80029a   50Gi       RWO            Retain           Released   gitlab/repo-data-gitlab-gitaly-0   standard                 5h

$ kubectl patch pv pvc-3acde8a6-1823-11e9-ad5f-42010a80029a -p "{\"spec\":{\"persistentVolumeReclaimPolicy\":\"Retain\"}}"
persistentvolume "pvc-3acde8a6-1823-11e9-ad5f-42010a80029a" patched

$ kubectl patch pv pvc-3b7da7c0-1823-11e9-ad5f-42010a80029a -p "{\"spec\":{\"persistentVolumeReclaimPolicy\":\"Retain\"}}"
persistentvolume "pvc-3b7da7c0-1823-11e9-ad5f-42010a80029a" patched

$ kubectl patch pv pvc-3acde8a6-1823-11e9-ad5f-42010a80029a --type merge -p "{\"metadata\":{\"labels\": {\"app\":\"postgresql\",\"release\":\"gitlab\"}}}"
persistentvolume "pvc-3acde8a6-1823-11e9-ad5f-42010a80029a" patched

$ kubectl patch pv pvc-3b7da7c0-1823-11e9-ad5f-42010a80029a --type merge -p "{\"metadata\":{\"labels\": {\"app\":\"gitaly\",\"release\":\"gitlab\"}}}"
persistentvolume "pvc-3b7da7c0-1823-11e9-ad5f-42010a80029a" patched
```

### Delete persistent volumes

After you uninstall this plan from the cluster, and **you are completely sure** you don't need its persisten volumes anymore, you can delete them using following commands:

```shell
$ kubectl get pvc | grep datadir-consul
datadir-consul-0   Bound     pvc-d4184653-179a-11e9-ad5f-42010a80029a   1Gi        RWO            standard       15h

$ kubectl delete pvc datadir-consul-0 -n kube-system
persistentvolumeclaim "datadir-consul-0" deleted

$ gcloud compute disks list --filter="-users:*"
NAME                                                             ZONE           SIZE_GB  TYPE         STATUS
gke-dev-a3f54e52-dynam-pvc-e41dcd6c-179a-11e9-ad5f-42010a80029a  us-central1-a  1        pd-standard  READY

$ gcloud compute disks delete gke-dev-a3f54e52-dynam-pvc-e41dcd6c-179a-11e9-ad5f-42010a80029a --zone=us-central1-a
The following disks will be deleted:
 - [gke-dev-a3f54e52-dynam-pvc-e41dcd6c-179a-11e9-ad5f-42010a80029a]
in [us-central1-a]

Do you want to continue (Y/n)?  y

Deleted [https://www.googleapis.com/compute/v1/projects/mtm-default-1/zones/us-central1-a/disks/gke-dev-a3f54e52-dynam-pvc-e41dcd6c-179a-11e9-ad5f-42010a80029a].
```

## Troubleshooting

Sometimes, especially if you install/uninstall the Terraform configuration several time, you may end up with a broken installation of a Helm chart. Run this command to purge it, and try reinstall once again:

```shell
helm del --purge gitlab
```
