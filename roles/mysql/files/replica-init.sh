#!/bin/bash
set -e

echo "Waiting for primary to be ready..."
until mysql -h"${PRIMARY_HOST}" -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1" &>/dev/null; do
  sleep 2
done

echo "Creating replication user on primary..."
mysql -h"${PRIMARY_HOST}" -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "
  CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED WITH mysql_native_password BY 'replpass';
  GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
  FLUSH PRIVILEGES;
"

echo "Configuring replica..."
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "
  STOP REPLICA;
  CHANGE REPLICATION SOURCE TO
    SOURCE_HOST='${PRIMARY_HOST}',
    SOURCE_USER='repl',
    SOURCE_PASSWORD='replpass',
    SOURCE_AUTO_POSITION=1;
  START REPLICA;
"

echo "Replica configured."
