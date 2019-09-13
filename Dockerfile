FROM google/cloud-sdk:alpine

ADD cloud_sql_backup.sh cloud_sql_backup.sh

RUN addgroup -S csbgroup  && adduser -S csbuser -G csbgroup
RUN chown csbuser:csbgroup cloud_sql_backup.sh
USER csbuser

ENTRYPOINT ["./cloud_sql_backup.sh"]
