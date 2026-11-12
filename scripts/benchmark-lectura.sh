#!/bin/bash
# Fase 5: benchmark de solo lectura con Sysbench y comparación de destinos.
#
# Uso: ./scripts/benchmark-lectura.sh [-t HILOS] [-d SEGUNDOS] [-u]
#   -t HILOS     hilos (conexiones simultáneas)      (por defecto 10)
#   -d SEGUNDOS  duración de cada prueba              (por defecto 60)
#   -u           incluir "un solo esclavo vía NGINX" (levanta un NGINX temporal)
#
# Mide, con los mismos parámetros:
#   1. Vía NGINX          nginx-lb:3308       (2 esclavos, least_conn)
#   2. Directo a 1 nodo   mysql-slave1:3306
#   3. (con -u) 1 esclavo vía NGINX (NGINX temporal que apunta solo a slave1)
#
# Requisitos: contenedores arriba, usuario sbtest creado y dataset cargado
# (ver "Benchmark con Sysbench (Fase 5)" en el README).

cd "$(dirname "$0")/.." || exit 1

THREADS=10; TIME=60; SOLO1=0
while getopts "t:d:u" o; do
  case $o in
    t) THREADS=$OPTARG ;;
    d) TIME=$OPTARG ;;
    u) SOLO1=1 ;;
    *) sed -n '2,15p' "$0"; exit 1 ;;
  esac
done

[ -f .env ] || { echo "Falta .env (ver README)."; exit 1; }
set -a; . ./.env; set +a
[ -n "$SYSBENCH_PASSWORD" ] || { echo "Falta SYSBENCH_PASSWORD en .env."; exit 1; }

for n in mysql-master mysql-slave1 mysql-slave2 nginx-lb; do
  [ "$(docker inspect -f '{{.State.Running}}' $n 2>/dev/null)" = true ] || { echo "$n no está corriendo. Ejecuta: docker compose up -d"; exit 1; }
done

# El dataset debe estar completo en los tres nodos
for n in mysql-master mysql-slave1 mysql-slave2; do
  c=$(docker exec $n sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT COUNT(*) FROM sbtest.sbtest1"' 2>/dev/null)
  [ "$c" = "1000000" ] || { echo "$n no tiene el dataset completo (filas: ${c:-ninguna}). Ejecuta el prepare del README."; exit 1; }
done

bench() {  # $1=host $2=puerto $3=etiqueta
  local salida
  salida=$(docker compose run --rm -T sysbench oltp_read_only \
    --mysql-host="$1" --mysql-port="$2" --mysql-user=sbtest --mysql-password="$SYSBENCH_PASSWORD" \
    --mysql-db=sbtest --tables=1 --table-size=1000000 \
    --threads="$THREADS" --time="$TIME" run 2>&1)
  echo "$salida" | awk -v l="$3" '
    /transactions:/ {t=substr($3,2)}
    /queries:/      {q=substr($3,2)}
    /avg:/          {a=$2}
    /95th/          {p=$3}
    /max:/          {m=$2}
    /ignored errors:/ {e=$3}
    END { if (t=="") { printf "%-34s FALLÓ (revisa credenciales/red)\n", l; exit 1 }
          printf "%-34s %8s %10s %9s %9s %9s %6s\n", l, t, q, a, p, m, e }'
}

echo "Sysbench oltp_read_only | $THREADS hilos | ${TIME}s por prueba | 1 tabla x 1.000.000 filas"
echo
printf "%-34s %8s %10s %9s %9s %9s %6s\n" "Destino" "TPS" "QPS" "avg(ms)" "p95(ms)" "max(ms)" "err"
printf '%.0s-' {1..92}; echo

# Calentamiento (no se reporta)
docker compose run --rm -T sysbench oltp_read_only \
  --mysql-host=nginx-lb --mysql-port=3308 --mysql-user=sbtest --mysql-password="$SYSBENCH_PASSWORD" \
  --mysql-db=sbtest --tables=1 --table-size=1000000 --threads="$THREADS" --time=10 run >/dev/null 2>&1

bench nginx-lb 3308 "Vía NGINX (2 esclavos)"
bench mysql-slave1 3306 "Directo a 1 esclavo (slave1)"

if [ $SOLO1 -eq 1 ]; then
  NET=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' nginx-lb)
  CONF=$(mktemp)
  cat > "$CONF" <<'EOF'
worker_processes auto;
events { worker_connections 4096; }
stream {
  upstream s1 { server mysql-slave1:3306; }
  server { listen 3308; proxy_pass s1; }
}
EOF
  chmod 644 "$CONF"
  docker run -d --rm --name nginx-s1 --network "$NET" -v "$CONF:/etc/nginx/nginx.conf:ro" nginx:1.27 >/dev/null
  trap 'docker stop nginx-s1 >/dev/null 2>&1; rm -f "$CONF"' EXIT
  sleep 2
  bench nginx-s1 3308 "Vía NGINX (1 esclavo)"
fi

echo
echo "TPS/QPS: más alto es mejor. Latencia (avg, p95, max): más baja es mejor."
echo "Todos los contenedores comparten la CPU del host: ver README (limitaciones)."
