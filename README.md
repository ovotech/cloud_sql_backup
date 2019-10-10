# cloud_sql_backup
[![CircleCI](https://circleci.com/gh/ovotech/cloud_sql_backup/tree/master.svg?style=svg&circle-token=80b72848ac9c5222d1b58b480a261b83ad8cc1e3)](https://circleci.com/gh/ovotech/cloud_sql_backup/tree/master)

This is a bash script that can be used for backing up GCP Cloud SQL instances. It works by restoring an existing GCP managed backup to a new ephemeral db instance, and exporting an SQL dump from there into a GCS bucket.

## Install

The `cloud_sql_backup.sh` script can be used on its own, or in a [Docker image](https://hub.docker.com/r/ovotech/cloud_sql_backup) we've prepared.

### Pre-requisites

1. An automated or on-demand GCP managed backup. Go [here](https://cloud.google.com/sql/docs/mysql/backup-recovery/backing-up) for help enabling.
2. The host running the script must have these tools installed:

    - cut
    - date
    - gcloud
    - head
    - sed
    - tr

## Configuring

The script requires some environment variables in order to function correctly:

| Name        | Description   | Example |
| ------------- |-------------|-------------|
| DB_VERSION    | The version of the ephemeral database instance that'll be created | "POSTGRES_9_6" |
| DB_NAME       | The database name that'll be exported to GCS | "my-db" |
| INSTANCE_CPU  | vCPUs of the ephemeral instance | "4" |
| INSTANCE_ENV | Name of environment the backup process is running in. It's used in the ephemeral instance name | "nonprod" |
| INSTANCE_MEM | Memory of instance | "7680MiB" |
| INSTANCE_NAME_PREFIX | Prefix to add to the start of instance name | "my-backup" |
| INSTANCE_REGION | Instance region | "europe-west1" |
| INSTANCE_STORAGE_SIZE_GB | Disk storage capacity (must be greater than the capacity of the original instance the GCP back is taken from) | "4000" |
| INSTANCE_STORAGE_TYPE | SSD (default) or HDD | "SSD" |
| PROJECT | The GCP project | "my-gcp-project" |
| SA_KEY_FILEPATH | The path to the GCP service account's .json key | "/secrets/gcp/backup-key.json" |
| SOURCE_BACKUP_INSTANCE | Name of instance that you want backing up | "uat-db" |
| TARGET_BACKUP_BUCKET | URI of GCS bucket that the backup file will get written to | "gs://my-gcs-bucket" |

## Why is this required?

GCP provide their own automated daily backup process, which is very easy to enable, so why is this required?

[According to GCP](https://cloud.google.com/sql/docs/mysql/backup-recovery/backing-up), "All data on an instance, **including backups**, is permanently lost when that instance is deleted". They recommend exporting your data to cloud storage for longer term persistence. That export process, however, can have a serious impact on the performance of your database while it's taking place.

This script solves these problems by:

* Creating a database instance from the latest automated GCP-managed backup
* Giving the database instance the required permissions to write to a GCS bucket
* Exporting to an SQL dump file in a GCS bucket

The ephemeral database instance and elevated permissions are then deleted/removed.

## What permissions are required?

When this script runs using a GCP service account, it'll need a specific set of permissions in order to elevate the database instance service account's permissions, and check that the SQL dump file has appeared in the GCS bucket:

```json
  permissions = [
    "cloudsql.backupRuns.get",
    "cloudsql.backupRuns.list",
    "cloudsql.instances.create",
    "cloudsql.instances.delete",
    "cloudsql.instances.export",
    "cloudsql.instances.get",
    "cloudsql.instances.restoreBackup",
    "storage.buckets.get",
    "storage.buckets.getIamPolicy",
    "storage.buckets.setIamPolicy",
    "storage.buckets.update",
    "storage.objects.get"
  ]
  ```

## Notes

### Permissive Role

The least privileged role for the script to succeed, as detailed [here](#what-permissions-are-required), is permissive. The `"cloudsql.instances.delete"` permission alone will allow anyone with the key, for the GCP service account you use, to delete any Cloud SQL instance in its GCP project.

### Instance Deletion

The final step in `cloud_sql_backup.sh` is to delete the ephemeral db instance that's been used to create the SQL dump. There's a hard-coded check at this point in the script to only perform the instance deletion when the instance name contains the string `"backup"`.

### Naming Format

To prevent a race condition, the script creates a name, to be used for both the ephemeral instance and the S3 SQL dump object, that's suffixed by a 5 character random string:

```
name = <instance_name_prefix>-<instance_env>-<timestamp>-<gcp_managed_backup_id>-<random_string>
```

- `timestamp` is obtained by executing `date +%Y%m%d%H%M%S`
- `instance_name_prefix` and `instance_env` are obtained from [env vars](#Configuring)
- `gcp_managed_backup_id` is the ID of the latest GCP managed backup
- `random_string` is the value of `LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 5`

### Backup candidate

The ID of the latest successful GCP managed backup is obtained using:

```bash
BACKUP_DATA=$(gcloud sql backups list \
  --instance "$SOURCE_BACKUP_INSTANCE" \
  --filter STATUS=SUCCESSFUL \
  --limit 1 | sed 1,1d | tr -s ' ')
BACKUP_ID=$(echo "$BACKUP_DATA" | cut -d ' ' -f 1)
```

Whilst it's recommended to monitor for failed/successful `cloud_sql_backup.sh` script executions, this can't be relied upon to report freshness of data. For example, your GCP managed backups may start failing, but the `cloud_sql_backup.sh` script will keep succeeding, but with out-of-date data (based on the last successful GCP managed backup).

### Completion Check

The penultimate task of the `cloud_sql_backup.sh` script is to poll GCS using `gsutil` to verify the object (SQL dump) has arrived in GCS as expected. This has to be performed out-of-band of the SQL dump process, as the dump is an operation that's triggered on the ephemeral db instance (using `gcloud sql export sql`).