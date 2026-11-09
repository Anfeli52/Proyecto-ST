#!/bin/bash
# Fase 4 (en vivo): caída de slave1 + escrituras durante la caída + recuperación
cd "$(dirname "$0")/.." || exit 1

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'; MAG=$'\e[35m'; CYN=$'\e[36m'; BLD=$'\e[1m'; RST=$'\e[0m'
OUT=/tmp/fase4-vivo.txt
LOG=/tmp/lecturas-fase4-vivo.log
F_RUN=/tmp/f4_run; F_EXCL=/tmp/f4_excl; F_RECOV=/tmp/f4_recov; F_BACK=/tmp/f4_back
rm -f $F_RUN $F_EXCL $F_RECOV $F_BACK; : > $OUT; echo "t nodo tardo_s" > $LOG

for n in mysql-master mysql-slave1 mysql-slave2; do
  [ "$(docker inspect -f '{{.State.Health.Status}}' $n 2>/dev/null)" = healthy ] || { echo "$n no está healthy. Revisa docker compose ps."; exit 1; }
done

IP1=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' mysql-slave1)
IP2=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' mysql-slave2)
nm() { if [ "$1" = "$IP1" ]; then echo slave1; elif [ "$1" = "$IP2" ]; then echo slave2; else echo "$1"; fi; }
q() { docker exec mysql-master sh -c "mysql -h nginx-lb -P $1 -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -N -B -e \"$2\"" 2>&1 | grep -v "Using a password"; }
rel() { echo $(( $(date +%s) - T0 )); }
say() { local t=$(( $(date +%s) - T0 )); printf '%s[t=%3ss] %s%s\n' "$1" "$t" "$2" "$RST"; printf '[t=%3ss] %s\n' "$t" "$2" >> $OUT; }
fase() { printf '\n%s═══ %s ═══%s\n' "$BLD$BLU" "$1" "$RST"; printf '\n═══ %s ═══\n' "$1" >> $OUT; }

watcher() {
  docker logs -f --tail 0 nginx-lb 2>&1 | grep --line-buffered -E '\[(error|warn)\]|:3306, ' | while IFS= read -r l; do
    if [[ "$l" == *"[error]"* || "$l" == *"[warn]"* ]]; then
      ip=$(sed -nE 's/.*upstream: "([0-9.]+):3306".*/\1/p' <<< "$l")
      who=$(nm "$ip")
      msg=$(sed -E 's/^[^]]*\] [0-9]+#[0-9]+: \*[0-9]+ //; s/ while connecting to upstream.*//' <<< "$l")
      case "$msg" in
        *"temporarily disabled"*)
          [ -f $F_EXCL ] || echo $(( $(date +%s) - T0 )) > $F_EXCL
          say "$YEL$BLD" "NGINX [warn]  $who EXCLUIDO del reparto (temporarily disabled, 10 s)";;
        *"timed out"*)        say "$YEL" "NGINX [error] timeout conectando a $who (esperó 5 s)";;
        *"No route to host"*) say "$YEL" "NGINX [error] sin ruta a $who (el contenedor ya no existe en la red)";;
        *"refused"*)          say "$YEL" "NGINX [error] conexión rechazada por $who (puerto cerrado)";;
        *)                    say "$YEL" "NGINX [error/warn] $who: $msg";;
      esac
    else
      read -r a b d <<< "$(sed -nE 's/.* -> ([0-9.]+):3306, ([0-9.]+):3306 estado=[0-9]+ duracion=([0-9.]+) s.*/\1 \2 \3/p' <<< "$l")"
      [ -n "$a" ] && say "$MAG" "NGINX reintentó: probó $(nm $a) (falló) → usó $(nm $b) · la conexión tardó ${d}s en total"
    fi
  done
}

reads() {
  local n1=0 n2=0 slow=0 k=0
  while [ -f $F_RUN ]; do
    s=$(date +%s.%N)
    r=$(q 3308 "SELECT @@server_id" | tail -1)
    e=$(date +%s.%N)
    d=$(awk "BEGIN{printf \"%.2f\", $e-$s}")
    st=$(docker inspect -f '{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}' mysql-slave1 2>/dev/null)
    t=$(( $(date +%s) - T0 ))
    echo "$t $r $d" >> $LOG
    case "$r" in
      2) nodo=slave1; n1=$((n1+1)); col=$CYN;;
      3) nodo=slave2; n2=$((n2+1)); col=$GRN;;
      *) nodo="ERROR: $r"; col=$RED;;
    esac
    if awk "BEGIN{exit !($d>1)}"; then
      slow=$((slow+1)); say "$RED$BLD" "lectura → $nodo  ${d}s  ⚠ LENTA   [slave1: $st]"
    else
      say "$col" "lectura → $nodo  ${d}s   [slave1: $st]"
    fi
    if [ -f $F_RECOV ] && [ ! -f $F_BACK ] && [ "$r" = "2" ]; then
      echo $t > $F_BACK; say "$MAG$BLD" "★ slave1 VOLVIÓ a recibir tráfico"
    fi
    k=$((k+1))
    if [ $((k%10)) -eq 0 ]; then
      say "$BLD" "── resumen de 10 lecturas: slave1=$n1  slave2=$n2  lentas=$slow ──"
      n1=0; n2=0; slow=0
    fi
    sleep 1
  done
}

cleanup() {
  rm -f $F_RUN
  pkill -f 'docker logs -f --tail 0 nginx-lb' 2>/dev/null
  [ "$(docker inspect -f '{{.State.Running}}' mysql-slave1 2>/dev/null)" = true ] || docker start mysql-slave1 >/dev/null 2>&1
}
trap cleanup EXIT INT

T0=$(date +%s)
fase "0. Estado inicial"
./scripts/verify-replication.sh | grep -E "GTID:|RESULTADO" | tee -a $OUT
GT0=$(q 3307 'SELECT @@global.gtid_executed' | tr -d '\n' | sed 's/.*://')
say "$BLD" "slave1=$IP1  slave2=$IP2  |  GTID maestro: $GT0"

touch $F_RUN
watcher & WPID=$!
reads & RPID=$!

fase "1. Línea base: todo sano (deben alternar slave1 y slave2)"
sleep 6

fase "2. Caída de slave1"
TS0=$(rel); say "$RED$BLD" ">>> docker stop mysql-slave1"
docker stop mysql-slave1 >/dev/null
TS1=$(rel); say "$RED$BLD" ">>> docker stop terminó (tardó $((TS1-TS0)) s)"
for i in $(seq 1 45); do [ -f $F_EXCL ] && break; sleep 1; done
if [ -f $F_EXCL ]; then
  EX=$(cat $F_EXCL)
  say "$YEL$BLD" "DETECCIÓN: NGINX excluyó a slave1 a los $((EX-TS0)) s de iniciar el apagado"
else
  say "$RED$BLD" "NGINX no marcó a slave1 como excluido en 45 s"
fi
say "$BLD" "Observa ahora: solo debería responder slave2"
sleep 6

fase "3. Escrituras con slave1 caído (por :3307 → maestro)"
q 3307 "CREATE DATABASE IF NOT EXISTS prueba_fase4" >/dev/null; say "$BLD" "escritura 1/7: CREATE DATABASE"; sleep 1
q 3307 "CREATE TABLE prueba_fase4.t (id INT AUTO_INCREMENT PRIMARY KEY, txt VARCHAR(50))" >/dev/null; say "$BLD" "escritura 2/7: CREATE TABLE"; sleep 1
for i in 1 2 3 4 5; do
  q 3307 "INSERT INTO prueba_fase4.t (txt) VALUES ('fila $i')" >/dev/null
  say "$BLD" "escritura $((i+2))/7: INSERT fila $i"; sleep 1
done
GT1=$(q 3307 'SELECT @@global.gtid_executed' | tr -d '\n' | sed 's/.*://')
say "$BLD" "GTID del maestro: $GT0 → $GT1 (slave1 no lo tiene todavía)"

fase "4. Recuperación de slave1"
touch $F_RECOV
TR=$(rel); say "$GRN$BLD" ">>> docker start mysql-slave1"
docker start mysql-slave1 >/dev/null
for i in $(seq 1 60); do [ -f $F_BACK ] && break; sleep 1; done
if [ -f $F_BACK ]; then BACK=$(cat $F_BACK); REC=$((BACK-TR)); else REC="NO VOLVIÓ"; fi
sleep 10

fase "5. Verificación de datos y replicación"
rm -f $F_RUN; wait $RPID 2>/dev/null
pkill -f 'docker logs -f --tail 0 nginx-lb' 2>/dev/null
./scripts/verify-replication.sh | tee -a $OUT
for n in mysql-master mysql-slave1 mysql-slave2; do
  c=$(docker exec $n sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT COUNT(*) FROM prueba_fase4.t"' 2>/dev/null)
  say "$BLD" "$n filas: $c"
done
q 3307 "DROP DATABASE prueba_fase4" >/dev/null
sleep 3

fase "RESUMEN"
TOT=$(awk 'NR>1' $LOG | wc -l)
S1=$(awk 'NR>1 && $2==2' $LOG | wc -l)
S2=$(awk 'NR>1 && $2==3' $LOG | wc -l)
SLOWN=$(awk 'NR>1 && $3>1' $LOG | wc -l)
ERRN=$(awk 'NR>1 && $2!=2 && $2!=3' $LOG | wc -l)
say "$BLD" "docker stop tardó:                $((TS1-TS0)) s"
[ -f $F_EXCL ] && say "$BLD" "detección (exclusión de slave1): $((EX-TS0)) s desde que se inició el apagado"
say "$BLD" "recuperación (start → 1.ª lectura de slave1): $REC s"
say "$BLD" "lecturas: $TOT  (slave1=$S1, slave2=$S2)  lentas=$SLOWN  errores=$ERRN"
awk 'NR>1 && $3>1 {printf "   lenta: t=%ss → %ss\n",$1,$3}' $LOG | tee -a $OUT
say "$BLD" "escrituras durante la caída: 7 transacciones (GTID $GT0 → $GT1)"
printf '\nCopia sin colores: %s\n' $OUT
