#!/bin/bash
# Fase 6: benchmarks de lectura, mixtos y con un esclavo caído (Sysbench).
#
# Uso: ./scripts/benchmark-mixto.sh [-t HILOS] [-d SEGUNDOS] [-w HILOS_ESCRITURA]
#   -t HILOS     hilos totales por prueba                    (por defecto 10)
#   -d SEGUNDOS  duración de cada prueba                     (por defecto 60)
#   -w HILOS     de los -t, cuántos escriben en la prueba dividida (por defecto 2)
#
# Escenarios (mismos hilos y duración en todos):
#   A1  Lectura (oltp_read_only)  vía NGINX :3308, 2 esclavos        (referencia Fase 5)
#   A2  Lectura                   directo al maestro (sin balanceo)
#   A3  Lectura                   directo a slave1 (sin proxy)
#   B1  Mixta (oltp_read_write)   vía NGINX :3307 (todo al maestro)
#   B2  Mixta dividida            lecturas -> :3308 | escrituras -> :3307, a la vez
#   C1  Lectura                   vía NGINX :3308 con slave1 caído
#   C2  Mixta dividida            con slave1 caído
# Extras: retraso de replicación durante las escrituras y tiempo que tarda
# slave1 en ponerse al día al volver.
#
# Siempre vuelve a encender slave1 al terminar (también con Ctrl+C).
# Salida: tabla por pantalla + resultados/fase6/ (logs crudos y resumen.csv).

cd "$(dirname "$0")/.." || exit 1

THREADS=10; TIME=60; WTHREADS=2
while getopts "t:d:w:" o; do
  case $o in
    t) THREADS=$OPTARG ;;
    d) TIME=$OPTARG ;;
    w) WTHREADS=$OPTARG ;;
    *) sed -n '2,8p' "$0"; exit 1 ;;
  esac
done
RTHREADS=$((THREADS - WTHREADS))

[ -f .env ] || { echo "Falta .env (ver README)."; exit 1; }
set -a; . ./.env; set +a
[ -n "$SYSBENCH_PASSWORD" ] || { echo "Falta SYSBENCH_PASSWORD en .env."; exit 1; }

for n in mysql-master mysql-slave1 mysql-slave2 nginx-lb; do
  [ "$(docker inspect -f '{{.State.Running}}' $n 2>/dev/null)" = true ] || { echo "$n no está corriendo. Ejecuta: docker compose up -d"; exit 1; }
done
for n in mysql-master mysql-slave1 mysql-slave2; do
  c=$(docker exec $n sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT COUNT(*) FROM sbtest.sbtest1"' 2>/dev/null)
  [ "$c" = "1000000" ] || { echo "$n no tiene el dataset completo (filas: ${c:-ninguna}). Ejecuta el prepare del README."; exit 1; }
done

OUT=resultados/fase6; mkdir -p "$OUT"
CSV="$OUT/resumen.csv"
echo "escenario,carga,hilos,tps,qps,avg_ms,p95_ms,max_ms,errores" > "$CSV"
LAGLOG="$OUT/lag.csv"; echo "escenario,segundo,slave1,slave2" > "$LAGLOG"

cleanup() {
  kill $LAGPID 2>/dev/null
  [ "$(docker inspect -f '{{.State.Running}}' mysql-slave1 2>/dev/null)" = true ] || docker start mysql-slave1 >/dev/null 2>&1
}
trap cleanup EXIT INT

sb() {  # $1=script $2=host $3=puerto $4=hilos $5=segundos  (stdout = salida de sysbench)
  docker compose run --rm -T sysbench "$1" \
    --mysql-host="$2" --mysql-port="$3" --mysql-user=sbtest --mysql-password="$SYSBENCH_PASSWORD" \
    --mysql-db=sbtest --tables=1 --table-size=1000000 \
    --threads="$4" --time="$5" run 2>&1
}

parse() {  # $1=archivo $2=escenario $3=carga $4=hilos -> imprime fila y la guarda en el CSV
  awk -v s="$2" -v c="$3" -v h="$4" -v csv="$CSV" '
    /transactions:/ {t=substr($3,2)}
    /queries:/      {q=substr($3,2)}
    /avg:/          {a=$2}
    /95th/          {p=$3}
    /max:/          {m=$2}
    /ignored errors:/ {e=$3}
    END { if (t=="") { printf "%-4s %-26s FALLÓ (ver log)\n", s, c; exit }
          printf "%-4s %-26s %5s %8s %9s %8s %8s %9s %5s\n", s, c, h, t, q, a, p, m, e
          printf "%s,%s,%s,%s,%s,%s,%s,%s,%s\n", s, c, h, t, q, a, p, m, e >> csv }' "$1"
}

lag_sampler() {  # $1=escenario: muestrea Seconds_Behind_Master cada 5 s hasta que se mate
  local s=0 l1 l2
  while true; do
    l1=$(docker exec mysql-slave1 sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW SLAVE STATUS\G"' 2>/dev/null | sed -n 's/^ *Seconds_Behind_Master: *//p')
    l2=$(docker exec mysql-slave2 sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW SLAVE STATUS\G"' 2>/dev/null | sed -n 's/^ *Seconds_Behind_Master: *//p')
    echo "$1,$s,${l1:-caído},${l2:-caído}" >> "$LAGLOG"
    s=$((s+5)); sleep 5
  done
}

wait_sync() {  # espera a que los esclavos encendidos tengan todos los GTID del maestro; imprime segundos
  local t0=$(date +%s) g ok n
  while [ $(( $(date +%s) - t0 )) -lt 300 ]; do
    g=$(docker exec mysql-master sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT @@global.gtid_executed"' 2>/dev/null | tr -d '\n')
    ok=1
    for n in mysql-slave1 mysql-slave2; do
      [ "$(docker inspect -f '{{.State.Running}}' $n)" = true ] || continue
      [ "$(docker exec $n sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -N -B -e \"SELECT GTID_SUBSET('$g', @@global.gtid_executed)\"" 2>/dev/null)" = 1 ] || ok=0
    done
    [ $ok -eq 1 ] && break
    sleep 1
  done
  echo $(( $(date +%s) - t0 ))
}

lectura() {  # $1=escenario $2=etiqueta $3=host $4=puerto
  sb oltp_read_only "$3" "$4" "$THREADS" "$TIME" > "$OUT/$1.log"
  parse "$OUT/$1.log" "$1" "$2" "$THREADS"
}

mixta_nginx() {  # $1=escenario
  sb oltp_read_write nginx-lb 3307 "$THREADS" "$TIME" > "$OUT/$1.log"
  parse "$OUT/$1.log" "$1" "Mixta r/w :3307 (maestro)" "$THREADS"
}

mixta_dividida() {  # $1=escenario
  lag_sampler "$1" & LAGPID=$!
  sb oltp_read_only nginx-lb 3308 "$RTHREADS" "$TIME" > "$OUT/$1-lectura.log" &
  local p1=$!
  sb oltp_write_only nginx-lb 3307 "$WTHREADS" "$TIME" > "$OUT/$1-escritura.log" &
  local p2=$!
  wait $p1 $p2
  kill $LAGPID 2>/dev/null; wait $LAGPID 2>/dev/null
  parse "$OUT/$1-lectura.log"   "$1" "  lecturas  -> :3308" "$RTHREADS"
  parse "$OUT/$1-escritura.log" "$1" "  escrituras -> :3307" "$WTHREADS"
}

echo "Sysbench Fase 6 | $THREADS hilos (dividida: $RTHREADS lectura + $WTHREADS escritura) | ${TIME}s por prueba | 1 tabla x 1.000.000 filas"
echo
printf "%-4s %-26s %5s %8s %9s %8s %8s %9s %5s\n" "Esc" "Carga" "Hilos" "TPS" "QPS" "avg(ms)" "p95(ms)" "max(ms)" "err"
printf '%.0s-' {1..92}; echo

# Calentamiento (no se reporta)
sb oltp_read_only nginx-lb 3308 "$THREADS" 20 >/dev/null

echo "# Todo sano"
lectura A1 "Lectura vía NGINX :3308" nginx-lb 3308
lectura A2 "Lectura directo al maestro" mysql-master 3306
lectura A3 "Lectura directo a 1 esclavo" mysql-slave1 3306
mixta_nginx B1; wait_sync >/dev/null
mixta_dividida B2; wait_sync >/dev/null

echo "# slave1 caído"
docker stop mysql-slave1 >/dev/null
sb oltp_read_only nginx-lb 3308 "$THREADS" 15 >/dev/null   # deja que NGINX detecte y excluya el nodo
lectura C1 "Lectura vía NGINX (1 vivo)" nginx-lb 3308
mixta_dividida C2

echo
echo "# Reincorporación de slave1"
docker start mysql-slave1 >/dev/null
SEG=$(wait_sync)
echo "slave1 tardó ${SEG}s en ponerse al día (GTID) tras las escrituras hechas mientras estaba caído"

echo
echo "# Retraso de replicación (Seconds_Behind_Master) durante las escrituras: máximo por escenario"
awk -F, 'NR>1 { for (i=3;i<=4;i++) if ($i ~ /^[0-9]+$/ && $i+0 > m[$1","i]) m[$1","i]=$i+0; seen[$1]=1 }
         END { for (s in seen) printf "  %s  slave1=%ss  slave2=%ss\n", s, m[s",3"]+0, m[s",4"]+0 }' "$LAGLOG" | sort

echo
echo "TPS/QPS: más alto es mejor. Latencia: más baja es mejor. Logs crudos y CSV en $OUT/"
