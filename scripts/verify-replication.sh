#!/bin/bash
# Uso: ./scripts/verify-replication.sh [esclavo1 esclavo2 ...]
# Sin argumentos revisa mysql-slave1 y mysql-slave2.

MASTER="mysql-master"
SLAVES=("$@")
[ ${#SLAVES[@]} -eq 0 ] && SLAVES=(mysql-slave1 mysql-slave2)

# GTID ejecutados por el maestro, en una sola línea
master_gtid=$(docker exec "$MASTER" sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT @@global.gtid_executed"' 2>/dev/null | tr -d '\n')
echo "Maestro ($MASTER) GTID: ${master_gtid:-NO DISPONIBLE}"

# Extrae un campo del resultado de SHOW SLAVE STATUS
get() { echo "$status" | sed -n "s/^ *$1: *//p"; }

fail=0
for s in "${SLAVES[@]}"; do
  echo
  echo "== $s =="
  status=$(docker exec "$s" sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW SLAVE STATUS\G"' 2>/dev/null)

  if [ -z "$status" ]; then
    echo "  FALLO: sin estado de replicación (contenedor caído o replicación no configurada)"
    fail=1
    continue
  fi

  io=$(get Slave_IO_Running)
  sql=$(get Slave_SQL_Running)
  lag=$(get Seconds_Behind_Master)
  ioerr=$(get Last_IO_Error)
  sqlerr=$(get Last_SQL_Error)

  # 1 si todo lo del maestro ya está en este esclavo
  synced=$(docker exec "$s" sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -N -B -e \"SELECT GTID_SUBSET('$master_gtid', @@global.gtid_executed)\"" 2>/dev/null)

  echo "  Slave_IO_Running:      $io"
  echo "  Slave_SQL_Running:     $sql"
  echo "  Seconds_Behind_Master: $lag"
  echo "  Last_IO_Error:         ${ioerr:-(vacío)}"
  echo "  Last_SQL_Error:        ${sqlerr:-(vacío)}"
  echo "  GTID al día con maestro: $([ "$synced" = "1" ] && echo sí || echo no)"

  ok=1
  [ "$io" = "Yes" ] || ok=0
  [ "$sql" = "Yes" ] || ok=0
  [ "$lag" = "0" ] || ok=0
  [ -z "$ioerr" ] || ok=0
  [ -z "$sqlerr" ] || ok=0
  [ "$synced" = "1" ] || ok=0

  if [ $ok -eq 1 ]; then
    echo "  RESULTADO: OK"
  else
    echo "  RESULTADO: FALLO"
    fail=1
  fi
done

exit $fail
