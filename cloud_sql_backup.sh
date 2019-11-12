#!/bin/bash

# Copyright 2019 OVO Technology
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

function echo_out() {
  echo "[$(date +%F_%T)] $1"
}

echo_out Starting backup job...

function cleanup() {
  echo
  echo '==================================================================================================='
  echo '|'
  echo '| Deleting new ephemeral DB instance'
  echo '|'
  echo '==================================================================================================='
  echo

  echo_out "Deleting ephemeral db instance used for backup: $TARGET_BACKUP_INSTANCE"
  if [[ $TARGET_BACKUP_INSTANCE == *"backup"* ]]; then
    gcloud -q sql instances delete "$TARGET_BACKUP_INSTANCE"
  else
    echo_out "String 'backup' not detected in target backup instance. Not deleting anything.."
  fi

  echo
  echo '==================================================================================================='
  echo '|'
  echo '| Revoking the new DB instance''s service account permission to write to GCS bucket'
  echo '|'
  echo '==================================================================================================='
  echo

  echo_out "Removing write access on $TARGET_BACKUP_BUCKET for $DB_SA_ID"
  gsutil acl ch -d "$DB_SA_ID" "$TARGET_BACKUP_BUCKET"
}

set -e

command -v cut >/dev/null 2>&1 || { echo "cut is required" && invalid=true; }
command -v date >/dev/null 2>&1 || { echo "date is required" && invalid=true; }
command -v gcloud >/dev/null 2>&1 || { echo "gcloud is required" && invalid=true; }
command -v head >/dev/null 2>&1 || { echo "head is required" && invalid=true; }
command -v sed >/dev/null 2>&1 || { echo "sed is required" && invalid=true; }
command -v tr >/dev/null 2>&1 || { echo "tr is required" && invalid=true; }

[ -z "$DB_VERSION" ] && echo "DB_VERSION is required" && invalid=true
[ -z "$DB_NAME" ] && echo "DB_NAME is required" && invalid=true
[ -z "$INSTANCE_CPU" ] && echo "INSTANCE_CPU is required" && invalid=true
[ -z "$INSTANCE_ENV" ] && echo "INSTANCE_ENV is required" && invalid=true
[ -z "$INSTANCE_MEM" ] && echo "INSTANCE_MEM is required" && invalid=true
[ -z "$INSTANCE_NAME_PREFIX" ] && echo "INSTANCE_NAME_PREFIX is required" && invalid=true
[ -z "$INSTANCE_REGION" ] && echo "INSTANCE_REGION is required" && invalid=true
[ -z "$INSTANCE_STORAGE_SIZE_GB" ] && echo "INSTANCE_STORAGE_SIZE_GB is required" && invalid=true
[ -z "$INSTANCE_STORAGE_TYPE" ] && echo "INSTANCE_STORAGE_TYPE is required" && invalid=true
[ -z "$PROJECT" ] && echo "PROJECT is required" && invalid=true
[ -z "$SA_KEY_FILEPATH" ] && echo "SA_KEY_FILEPATH is required" && invalid=true
[ -z "$SOURCE_BACKUP_INSTANCE" ] && echo "SOURCE_BACKUP_INSTANCE is required" && invalid=true
[ -z "$TARGET_BACKUP_BUCKET" ] && echo "TARGET_BACKUP_BUCKET is required" && invalid=true

if [ "$invalid" = true ] ; then
    exit 1
fi

echo_out "Setting up local gcloud"
gcloud auth activate-service-account --key-file="$SA_KEY_FILEPATH"
gcloud config set project "$PROJECT"

RANDOM_STRING=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 5)
TIMESTAMP=$(date +%Y%m%d%H%M%S)

echo_out "Grabbing details of the latest GCP backup to create sql backup from"
BACKUP_DATA=$(gcloud sql backups list \
  --instance "$SOURCE_BACKUP_INSTANCE" \
  --filter STATUS=SUCCESSFUL \
  --limit 1 | sed 1,1d | tr -s ' ')
BACKUP_ID=$(echo "$BACKUP_DATA" | cut -d ' ' -f 1)
BACKUP_TS=$(echo "$BACKUP_DATA" | cut -d ' ' -f 2)

if [ -z "$BACKUP_ID" ]; then
  echo_out "Empty backup Id found. Aborting."
  exit 1
fi

TARGET_BACKUP_INSTANCE=$INSTANCE_NAME_PREFIX-$INSTANCE_ENV-$TIMESTAMP-$BACKUP_ID-$RANDOM_STRING

echo
echo '==================================================================================================='
echo '|'
echo '| Creating new ephemeral DB instance to restore backup to'
echo '|'
echo '==================================================================================================='
echo

echo_out "Creating new DB instance $TARGET_BACKUP_INSTANCE that the daily GCP backup can be restored to"
gcloud sql instances create "$TARGET_BACKUP_INSTANCE" \
  --cpu="$INSTANCE_CPU" \
  --memory="$INSTANCE_MEM" \
  --region="$INSTANCE_REGION" \
  --storage-type="$INSTANCE_STORAGE_TYPE" \
  --storage-size="$INSTANCE_STORAGE_SIZE_GB" \
  --database-version="$DB_VERSION"

trap cleanup EXIT

echo
echo '==================================================================================================='
echo '|'
echo '| Restoring backup to new ephemeral DB instance'
echo '|'
echo '==================================================================================================='
echo

echo_out "Restoring to $TARGET_BACKUP_INSTANCE from daily GCP backup (id: $BACKUP_ID) which was created at $BACKUP_TS"
restore_rs=$(gcloud -q sql backups restore "$BACKUP_ID" \
  --restore-instance="$TARGET_BACKUP_INSTANCE" \
  --backup-instance="$SOURCE_BACKUP_INSTANCE" 2>&1 || true)
if [[ "${restore_rs}" != *"Restored"* ]]; then
  echo_out "Restore hasn't finished, sleeping to allow that to happen"
  sleep 600
fi

echo
echo '==================================================================================================='
echo '|'
echo '| Giving the new DB instance''s service account permission to write to GCS bucket'
echo '|'
echo '==================================================================================================='
echo

echo_out "Grabbing the GCP service account id from the newly created DB instance"
DB_SA_ID=$(gcloud sql instances describe "$TARGET_BACKUP_INSTANCE" | grep 'serviceAccountEmailAddress:' | tr -s ' ' | cut -d ' ' -f 2)

echo_out "Giving GCP service account: $DB_SA_ID permission to write future backup file to bucket: $TARGET_BACKUP_BUCKET"
gsutil acl ch -u "$DB_SA_ID":W "$TARGET_BACKUP_BUCKET"

echo
echo '==================================================================================================='
echo '|'
echo '| Creating SQL backup file of instance and exporting to GCS bucket'
echo '|'
echo '==================================================================================================='
echo

TARGET_BACKUP_URI=$TARGET_BACKUP_BUCKET/$TARGET_BACKUP_INSTANCE.gz
echo_out "Creating SQL backup file of instance: $TARGET_BACKUP_INSTANCE and exporting to $TARGET_BACKUP_URI"
export_rs=$(gcloud sql export sql "$TARGET_BACKUP_INSTANCE" "$TARGET_BACKUP_URI" \
  --database="$DB_NAME" 2>&1 || true)

if [[ $export_rs != *"sql operations wait"* ]] && [[ $export_rs != *"done"* ]]; then
  echo_out "Unexpected response returned for 'gcloud sql export sql...' command: $export_rs"
  exit 1
fi

echo
echo '==================================================================================================='
echo '|'
echo '| Checking the SQL backup has arrived in GCS'
echo '|'
echo '==================================================================================================='
echo

[[ -z "$GCS_VERIFY_MAX_CHECKS" ]] && MAX_CHECKS=10 || MAX_CHECKS="$GCS_VERIFY_MAX_CHECKS"
[[ -z "$GCS_VERIFY_TIME_INTERVAL_SECS" ]] && SLEEP_SECONDS=300 || SLEEP_SECONDS="$GCS_VERIFY_TIME_INTERVAL_SECS"

NUM_CHECKS=0

echo_out "Polling GCS to check the new object exists: $TARGET_BACKUP_URI (max_checks: $MAX_CHECKS, sleep_interval(s): $SLEEP_SECONDS)"

# disable non-zero status exit so 'gsutil -q stat' doesn't throw us out
set +e
while :; do
  ((NUM_CHECKS++))
  if gsutil -q stat "$TARGET_BACKUP_URI"; then
    echo_out "Object found in bucket"
    break
  fi
  if [[ $NUM_CHECKS == "$MAX_CHECKS" ]]; then
    echo_out "Reached check limit ($MAX_CHECKS). Aborting, but the 'gcloud sql export sql' op may still be in progress"
    break
  fi
  echo_out "Backup file not found in bucket, checking again in $SLEEP_SECONDS seconds"
  sleep "$SLEEP_SECONDS"
done
set -e
