10342  gcloud sql instances describe test-missing-db-2
10343  gsutil acl ch -u p423699399729-am8o7i@gcp-sa-cloud-sql.iam.gserviceaccount.com:W gs://orex-postgresbackup-nonprod
10344  gsutil acl ch -u p423699399729-am8o7i@gcp-sa-cloud-sql.iam.gserviceaccount.com:R gs://orex-postgresbackup-nonprod/test-missing-db
10345  gcloud sql import sql test-missing-db-2 gs://orex-postgresbackup-nonprod/test-missing-db --database=blah-db
