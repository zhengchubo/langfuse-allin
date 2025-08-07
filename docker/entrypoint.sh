#!/bin/sh

set -e

# postgres init
chown -R postgres:postgres /var/lib/postgresql/data
if [ ! -f /var/lib/postgresql/data/postgresql.conf ]; then
  su-exec postgres /usr/bin/initdb -D /var/lib/postgresql/data
fi


# redis init
if [ -n "$REDIS_AUTH" ]; then
  echo "Setting Redis password..."
  sed -i "s/# requirepass .*/requirepass $REDIS_AUTH/" /etc/redis.conf
fi

# start clickhouse
/bin/bash /entrypoint.sh &

# start supervisord
/usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf


waiting_for_connection(){
  until nc -z -w 3 "$1" "$2"; do
    >&2 echo "Waiting for connection to the $1 host on port $2"
    sleep 1
  done
}

waiting_for_db(){
  waiting_for_connection ${DB_HOST:-localhost} ${DB_PORT:-5432}
}

waiting_for_redis(){
  waiting_for_connection ${REDIS_HOST:-localhost} ${REDIS_PORT:-6379}
}

waiting_for_minio(){
  waiting_for_connection ${MINIO_HOST:-localhost} ${MINIO_PORT:-9000}
}

waiting_for_clickhouse(){
  waiting_for_connection ${CLICKHOUSE_HOST:-localhost} ${CLICKHOUSE_PORT:-8123}
  waiting_for_connection localhost 9000
}

waiting_for_db
waiting_for_redis
waiting_for_minio
waiting_for_clickhouse


cd /app
su-exec expressjs sh web/entrypoint.sh
su-exec expressjs mkdir -p /app/log/
su-exec expressjs node worker/dist/index.js > /app/log/worker.out.log 2> /app/log/worker.err.log &

if [ -n "$NEXT_PUBLIC_LANGFUSE_CLOUD_REGION" ]; then 
  su-exec expressjs node --import dd-trace/initialize.mjs ./web/server.js --keepAliveTimeout 110000; 
else 
  su-exec expressjs node ./web/server.js --keepAliveTimeout 110000; 
fi

tail -f /dev/null
