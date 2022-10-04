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

set -e

function echo_out() {
  echo -e "[$(date +%F_%T)] $1"
}

function post_count_metric() {
  if [[ -n $DATADOG_API_KEY ]];then
    hostname=$(hostname)
    currenttime=$(date +%s)
    curl  -X POST -H "Content-type: application/json" \
    -d "{ \"series\" :
             [{\"metric\":\"$1\",
              \"points\":[[$currenttime, 1]],
              \"type\":\"count\",
              \"interval\": 20,
              \"host\":\"$hostname\",
              \"tags\":[\"environment:${INSTANCE_ENV}\",\"team:${TEAM}\",\"db:${DB_NAME}\",\"instance:${SOURCE_BACKUP_INSTANCE}\"]}
            ]
    }" \
    "https://api.datadoghq.com/api/v1/series?api_key=$DATADOG_API_KEY"
  fi

  echo
  echo_out "$1 metric posted"
}

function target_instance_is_runnable() {
  gcloud sql instances describe "$TARGET_BACKUP_INSTANCE" | grep "state:" | grep "RUNNABLE" -c
}

function operation_has_finished() {
  gcloud sql operations list -i "$TARGET_BACKUP_INSTANCE" | grep "$1" | grep "DONE" -c
}

function all_operations_have_finished() {
  operation_details=$(gcloud sql operations list -i "$TARGET_BACKUP_INSTANCE" | sed 1,1d)
  number_of_operations=$(echo "$operation_details" | wc -l)
  completed_operations=$(echo "$operation_details" | grep "DONE" -c)

  if [[ "${completed_operations}" -lt "${number_of_operations}" ]]; then
    echo "0"
  else
    echo "1"
  fi
}

function wait_for_target_instance_to_be_created() {
  local NUM_CHECKS=0
  local MAX_CHECKS=10
  local SLEEP_SECONDS=30
  echo_out "Polling GCP to check the new instance is runnable: $TARGET_BACKUP_INSTANCE (max_checks: $MAX_CHECKS, sleep_interval(s): $SLEEP_SECONDS)"

  while :; do
    ((NUM_CHECKS+=1))
    if [[ "$(target_instance_is_runnable)" == "1" ]]; then
      echo_out "Target instance is runnable"
      break
    fi
    if [[ $NUM_CHECKS == "$MAX_CHECKS" ]]; then
      echo_out "Reached check limit ($MAX_CHECKS). Aborting."
      exit 1
    fi
    echo_out "Target instance not yet runnable, checking again in $SLEEP_SECONDS seconds"
    sleep "$SLEEP_SECONDS"
  done
}

function wait_for_restore_to_finish() {
  local NUM_CHECKS=0
  local MAX_CHECKS=10
  local SLEEP_SECONDS=60
  echo_out "Polling GCP to check whether restore to target instance has finished: $TARGET_BACKUP_INSTANCE (max_checks: $MAX_CHECKS, sleep_interval(s): $SLEEP_SECONDS)"

  while :; do
    ((NUM_CHECKS+=1))
    if [[ "$(operation_has_finished "RESTORE_VOLUME")" == "1" ]]; then
      echo_out "Restore has finished."
      break
    fi
    if [[ $NUM_CHECKS == "$MAX_CHECKS" ]]; then
      echo_out "Reached check limit ($MAX_CHECKS). Will attempt to continue, however, unlikely to be successful."
      break
    fi
    echo_out "Waiting for restore to finish, checking again in $SLEEP_SECONDS seconds"
    sleep "$SLEEP_SECONDS"
  done
}

function wait_for_all_operations_to_finish() {
  local NUM_CHECKS=0
  local MAX_CHECKS=10
  local SLEEP_SECONDS=60
  echo_out "Polling GCP to check whether all operations on target instance have finished: $TARGET_BACKUP_INSTANCE (max_checks: $MAX_CHECKS, sleep_interval(s): $SLEEP_SECONDS)"

  while :; do
    ((NUM_CHECKS+=1))
    if [[ "$(all_operations_have_finished)" == "1" ]]; then
      echo_out "All operations have finished."
      break
    fi
    if [[ $NUM_CHECKS == "$MAX_CHECKS" ]]; then
      echo_out "Reached check limit ($MAX_CHECKS). Will attempt to continue, however, unlikely to be successful."
      break
    fi
    echo_out "Not all operations have finished, checking again in $SLEEP_SECONDS seconds"
    sleep "$SLEEP_SECONDS"
  done
}

echo_out Starting backup job...

function cleanup() {
  if [[ "$success_count" -eq "$database_count" ]]; then
    post_count_metric "cloud.sql.backup.success.count"
  else
    post_count_metric "cloud.sql.backup.failure.count"
  fi

  echo
  echo '==================================================================================================='
  echo '|'
  echo '| Deleting new ephemeral DB instance'
  echo '|'
  echo '==================================================================================================='
  echo

  wait_for_all_operations_to_finish

  echo_out "Deleting ephemeral db instance used for backup: $TARGET_BACKUP_INSTANCE"
  if [[ $TARGET_BACKUP_INSTANCE == *"backup"* ]]; then
    gcloud -q sql instances delete "$TARGET_BACKUP_INSTANCE"
    post_count_metric "cloud.sql.backup.cleanup.count"
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
command -v jq >/dev/null 2>&1 || { echo "jq is required, installing it" && apt install -y jq; }

[ -z "$DB_NAME" ] && echo "DB_NAME is required" && invalid=true
[ -z "$INSTANCE_CPU" ] && echo "INSTANCE_CPU is required" && invalid=true
[ -z "$INSTANCE_ENV" ] && echo "INSTANCE_ENV is required" && invalid=true
[ -z "$INSTANCE_MEM" ] && echo "INSTANCE_MEM is required" && invalid=true
[ -z "$INSTANCE_NAME_PREFIX" ] && echo "INSTANCE_NAME_PREFIX is required" && invalid=true
[ -z "$INSTANCE_REGION" ] && echo "INSTANCE_REGION is required" && invalid=true
[ -z "$INSTANCE_STORAGE_TYPE" ] && echo "INSTANCE_STORAGE_TYPE is required" && invalid=true
[ -z "$PROJECT" ] && echo "PROJECT is required" && invalid=true
[ -z "$SA_KEY_FILEPATH" ] && echo "SA_KEY_FILEPATH is required" && invalid=true
[ -z "$SOURCE_BACKUP_INSTANCE" ] && echo "SOURCE_BACKUP_INSTANCE is required" && invalid=true
[ -z "$TARGET_BACKUP_BUCKET" ] && echo "TARGET_BACKUP_BUCKET is required" && invalid=true
# default timeout for sql export: 3 hours
[ -z "$TIMEOUT" ] && TIMEOUT=10800

if [ "$invalid" = true ] ; then
    exit 1
fi

echo_out "Setting up local gcloud"
gcloud auth activate-service-account --key-file="$SA_KEY_FILEPATH"
gcloud config set project "$PROJECT"

RANDOM_STRING=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 5)
TIMESTAMP=$(date +%Y%m%d%H%M%S)
success_count=0
database_count=0

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

echo_out "Grabbing the required database version and instance storage size"
SOURCE_INSTANCE_DETAILS=$(gcloud sql instances describe "$SOURCE_BACKUP_INSTANCE")
DB_VERSION=$(echo "$SOURCE_INSTANCE_DETAILS" | grep 'databaseVersion:' | tr -s ' ' | cut -d ' ' -f 2)
INSTANCE_STORAGE_SIZE_GB=$(echo "$SOURCE_INSTANCE_DETAILS" | grep 'dataDiskSizeGb:' | tr -s ' ' | cut -d \' -f 2)

if [ -z "$DB_VERSION" ]; then
  echo_out "Empty database version found. Aborting."
  exit 1
fi

if [ -z "$INSTANCE_STORAGE_SIZE_GB" ]; then
  echo_out "Empty instance storage size found. Aborting."
  exit 1
fi

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
  --database-version="$DB_VERSION" \
  --require-ssl
echo

trap cleanup EXIT

wait_for_target_instance_to_be_created

echo
echo '==================================================================================================='
echo '|'
echo '| Restoring backup to new ephemeral DB instance'
echo '|'
echo '==================================================================================================='
echo

post_count_metric "cloud.sql.backup.started.count"
echo_out "Restoring to $TARGET_BACKUP_INSTANCE from daily GCP backup for $SOURCE_BACKUP_INSTANCE (id: $BACKUP_ID) which was created at $BACKUP_TS"
restore_rs=$(gcloud -q sql backups restore "$BACKUP_ID" \
  --restore-instance="$TARGET_BACKUP_INSTANCE" \
  --backup-instance="$SOURCE_BACKUP_INSTANCE" 2>&1 || true)
if [[ "${restore_rs}" != *"Restored"* ]]; then
  wait_for_restore_to_finish
else
  echo_out "Restore has finished."
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

echo_out "Picked up database names from env: $DB_NAME"

for db in ${DB_NAME//:/ } ; do
    echo_out "Processing database: $db"
    database_count=$((database_count + 1))
    TARGET_BACKUP_URI="$TARGET_BACKUP_BUCKET/${TARGET_BACKUP_INSTANCE}_$db.gz"
    echo_out "Creating SQL backup file of instance: $TARGET_BACKUP_INSTANCE and exporting to $TARGET_BACKUP_URI"

    set +e

    gcloud sql export sql "$TARGET_BACKUP_INSTANCE" "$TARGET_BACKUP_URI" \
	--database="$db" --async --format=json > /tmp/sql-export.log 2>&1
    EXIT_CODE=$?
    echo_out "SQL export exit code: $EXIT_CODE"

    cat /tmp/sql-export.log

    # check if there's any error
    [[ $EXIT_CODE -ne 0 ]] && {
	# nothing we can do, export failed
        exit 1
    }

    set -e


    JOB_ID="$(jq '.[0]' < /tmp/sql-export.log | \
	sed -r 's/.*operations\/(.*)"/\1/')"

    # validate UUID
    if [[ ! ${JOB_ID//-/} =~ ^[[:xdigit:]]{32}$ ]];
    then
        echo_out "Invalid job number, not a UUID"
        exit 1
    fi

    END=$((SECONDS+TIMEOUT))

    while [[ $SECONDS -lt $END ]];
    do

	sleep 300

        STATUS="$(gcloud beta sql operations describe "$JOB_ID" --format=json | \
	    jq -r '.status')"

	case $STATUS in
	DONE)
	    echo_out "job $JOB_ID completed"
	    break
	    ;;
	RUNNING|PENDING)
	    # NOP
	    ;;
	SQL_OPERATION_STATUS_UNSPECIFIED)
	    echo_out "job $JOB_ID has unknown status"
            STATUS="$(gcloud beta sql operations describe "$JOB_ID" --format=json)"
	    echo_out "$STATUS"
	    exit 1
	    ;;
	*)
	    echo_out "job $JOB_ID has unknown status"
            STATUS="$(gcloud beta sql operations describe "$JOB_ID" --format=json)"
	    echo_out "$STATUS"
	    exit 1
	    ;;
        esac

    done

    rm -f /tmp/sql-export.log


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
      ((NUM_CHECKS+=1))
      if gsutil -q stat "$TARGET_BACKUP_URI"; then
        echo_out "Object found in bucket"
        ((success_count++))
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
done
