#!/bin/bash
set -e

mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<EOF
CHANGE MASTER TO
  MASTER_HOST='mysql-master',
  MASTER_USER='$MYSQL_REPL_USER',
  MASTER_PASSWORD='$MYSQL_REPL_PASSWORD',
  MASTER_AUTO_POSITION=1,
  GET_MASTER_PUBLIC_KEY=1;
START SLAVE;
-- Solo lectura persistente (se guarda en mysqld-auto.cnf y sobrevive a reinicios).
-- En slave1/slave2 ya vienen de su my.cnf; aqui se refuerza y cubre a los demas.
SET PERSIST read_only=ON;
SET PERSIST super_read_only=ON;
EOF
