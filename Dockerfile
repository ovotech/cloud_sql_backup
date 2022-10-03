FROM google/cloud-sdk:319.0.0-alpine

ADD cloud_sql_backup.sh cloud_sql_backup.sh
RUN gcloud components install beta -q

RUN addgroup -S csbgroup  && adduser -S csbuser -G csbgroup
RUN chown csbuser:csbgroup cloud_sql_backup.sh
USER csbuser

ENTRYPOINT ["./cloud_sql_backup.sh"]
