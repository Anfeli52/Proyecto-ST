# 2.4. Fase 4 - Health Checks y Tolerancia a fallos (César)

# 2.4. Fase 4 — NGINX: Health checks y tolerancia a fallos

**Responsable:** Cesar Andrés Diaz Jimenez
**Proyecto:** Balanceo de carga de lectura MySQL (replicación maestro-esclavo + NGINX stream, todo en Docker Compose)
**Ruta de trabajo:** `~/Proyecto-ST` (Ubuntu, sistema de archivos de Linux, no `/mnt/c`)
**Depende de:** Fase 3 (balanceo básico con `least_conn`)

---

# Resumen

## Qué se hizo

Se estudió, configuró y midió el mecanismo con el que NGINX detecta que un esclavo cayó y deja de enviarle tráfico, y cómo lo reincorpora al volver. Se simularon caídas de `mysql-slave1` con `docker stop`, se midieron los tiempos de detección y recuperación, y se comprobó que los datos escritos en el maestro durante la caída llegan a `slave1` al volver (replicación por GTID).

No se cambiaron los valores de `max_fails`, `fail_timeout` ni `proxy_connect_timeout`: la Fase 3 ya traía el mecanismo. El aporte de esta fase es entenderlo, hacerlo observable (se añadió el tiempo de conexión al log), medirlo y documentar sus límites. También se crearon dos scripts reproducibles de prueba.

## Resultado en una tabla

| Medición | Resultado |
| --- | --- |
| Errores vistos por los clientes durante la caída | **0** en todas las corridas |
| Detección (apagado de slave1 → exclusión por NGINX) | 8 a 12 s según la corrida |
| Costo por cliente "sacrificado" | 3 a 5 s de espera, sin error |
| Recuperación (arranque de slave1 → primera lectura suya) | 1 s, 11 s y 14 s según el momento (depende de `fail_timeout`) |
| Datos escritos con slave1 caído | Llegaron a slave1 por GTID (5/5/5 filas, `OK` en ambos esclavos) |

## Por qué se hizo así

- **Health check TCP y no HTTP.** MySQL no habla HTTP. En el módulo `stream` (capa 4) el único chequeo posible es abrir la conexión TCP al puerto 3306.
- **Health checks pasivos.** La imagen `nginx:1.27` es la versión de código abierto. La directiva `health_check` (chequeo **activo**) solo existe en NGINX Plus. Lo disponible es el chequeo **pasivo**: `max_fails` y `fail_timeout`. NGINX observa las conexiones reales y, si una falla, la cuenta.
- **Reintento automático dentro de `stream`.** Cuando la conexión a un nodo falla, NGINX prueba con el siguiente. Por eso ningún cliente recibió error: solo esperó más.
- **Se añadió `$upstream_connect_time` al log** para ver cuánto costó cada intento fallido y cuál nodo se probó primero.

## Health check TCP vs HTTP

|  | TCP | HTTP |
| --- | --- | --- |
| Qué pregunta | ¿Se puede abrir conexión al puerto? | ¿La aplicación responde bien a una petición? |
| Capa | 4 (`stream`) | 7 (`http`) |
| Qué verifica | Que algo escucha | Que el servicio devuelve, por ejemplo, un 200 |
| Para MySQL | Es el que aplica | No aplica |

## Pasivo vs activo

|  | Pasivo | Activo |
| --- | --- | --- |
| Cómo detecta | Observa conexiones reales; si una falla, la cuenta | NGINX prueba por su cuenta cada X segundos |
| Ventaja | Sin tráfico extra | Detecta la caída antes de que un cliente la sufra |
| Desventaja | El primer cliente que choca paga el costo; sin tráfico no hay detección | Genera tráfico de prueba |
| Directivas | `max_fails`, `fail_timeout` | `health_check` (solo NGINX Plus) |
| Disponible aquí | Sí | No |

## Parámetros del health check pasivo

| Parámetro | Valor | Qué controla | Si se baja | Si se sube |
| --- | --- | --- | --- | --- |
| `max_fails` | 2 | Fallos necesarios para excluir al nodo | Detecta más rápido, pero un hipo de red puede sacar un nodo sano | Más tolerante, pero más clientes pagan el costo |
| `fail_timeout` | 10 s | Ventana en que se cuentan los fallos **y** tiempo que el nodo queda excluido | Reintenta antes al nodo (recupera más rápido, más intentos fallidos si sigue caído) | Menos intentos contra un nodo muerto, pero tarda más en reincorporarlo |
| `proxy_connect_timeout` | 5 s | Espera máxima por intento de conexión | Cada cliente sacrificado espera menos | Un nodo lento no se descarta por error, pero el cliente espera más |

Dos perillas distintas para dos objetivos: bajar `proxy_connect_timeout` reduce lo que **cada** cliente sacrificado espera; subir `fail_timeout` reduce **cuántos** clientes son sacrificados.

---

# Comandos y configuración, en orden

## Preparación del entorno (Ubuntu)

Las fases 1 a 3 se levantaron en Ubuntu a partir del repositorio. El orden importa, por los problemas descritos al final.

### 1. Clonar y preparar

```bash
cd ~
git clone <https://github.com/Anfeli52/Proyecto-ST.git>
cd Proyecto-ST

cat > .env <<EOF
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 24)
MYSQL_REPL_USER=replicador
MYSQL_REPL_PASSWORD=$(openssl rand -hex 12)
EOF
chmod 600 .env

sed -i 's/\r$//' scripts/*.sh mysql/slave-init/*.sh mysql/*/my.cnf nginx/nginx.conf
chmod 644 mysql/*/my.cnf nginx/nginx.conf
chmod +x scripts/*.sh mysql/slave-init/*.sh
```

- `git clone` descarga el proyecto.
- `.env` no está en el repo: se genera con contraseñas aleatorias (`openssl rand -hex`) y `chmod 600` lo deja legible solo por el dueño.
- `sed 's/\r$//'` quita los saltos de línea de Windows (CRLF), que rompen los scripts `.sh`.
- `chmod 644` en los `.cnf`: MySQL ignora configuraciones escribibles por todos.
- `chmod +x` da permiso de ejecución a los scripts.

### 2. Quitar `super_read_only` solo para el primer arranque

```bash
sed -i '/^super_read_only=1$/d' mysql/slave1/my.cnf mysql/slave2/my.cnf
```

- Con `super_read_only=1` activo, el primer arranque puede fallar porque la imagen de MySQL necesita escribir al inicializar el volumen. Se reactiva al final.

### 3. Arranque en orden

```bash
docker compose config --quiet && echo "compose válido"
docker compose up -d mysql-master
docker compose ps

docker exec mysql-master sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER IF NOT EXISTS \"$MYSQL_REPL_USER\"@\"%\" IDENTIFIED BY \"$MYSQL_REPL_PASSWORD\"; GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO \"$MYSQL_REPL_USER\"@\"%\";"'

docker compose up -d
docker compose ps
./scripts/verify-replication.sh
```

- `config --quiet` valida el YAML sin imprimir nada si está bien.
- Se levanta primero solo el maestro y se crea a mano el usuario `replicador` (ningún archivo del repo lo crea).
- `up -d` crea los esclavos y NGINX; los esclavos ejecutan `01-replication.sh` la primera vez.
- `verify-replication.sh` debe dar `OK` en ambos esclavos.

### 4. Reactivar `super_read_only` y recrear

```bash
sed -i 's/^read_only=1$/read_only=1\nsuper_read_only=1/' mysql/slave1/my.cnf mysql/slave2/my.cnf
docker compose up -d --force-recreate mysql-slave1 mysql-slave2
./scripts/verify-replication.sh
```

- Se usa `-force-recreate` y no `restart` porque `sed -i` reemplaza el archivo y el bind mount queda apuntando al original (ver "Problemas comunes").

### 5. Comprobaciones de las fases 1 a 3

```bash
docker exec mysql-slave1 sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "SELECT @@read_only, @@super_read_only"' 2>/dev/null

for i in 1 2 3 4 5 6; do
  docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3308 -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT @@server_id"' 2>/dev/null
done

docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3308 -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE x;"' 2>&1 | grep -i read-only
```

- Resultado: `1 1`, lecturas alternando `3, 2, 3, 2, 3, 2` y el error `ERROR 1290 ... super-read-only` al escribir por el 3308.

---

## Paso 1. Entender el health check

Sin comandos. Se estudió la diferencia TCP/HTTP y pasivo/activo (ver resumen). La pregunta de verificación: con slave1 apagado y sin clientes, NGINX **asume que el nodo está sano**, porque el chequeo pasivo solo reacciona cuando una conexión real falla.

## Paso 2. Hacer observable lo que NGINX decide

### 2.1 Copia de seguridad e IPs de los nodos

```bash
cd ~/Proyecto-ST
cp nginx/nginx.conf /tmp/nginx.conf.fase3.bak
docker inspect -f '{{.Name}} {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' mysql-slave1 mysql-slave2
```

- La copia queda fuera del repo por si hay que volver atrás.
- Los logs de NGINX muestran IPs, no nombres. Resultado:

| Nodo | IP | `server_id` |
| --- | --- | --- |
| mysql-slave1 | `172.18.0.3` | 2 |
| mysql-slave2 | `172.18.0.4` | 3 |

### 2.2 Ampliar el `log_format`

Editar `nginx/nginx.conf` (con `nano` o `vim`) para que el formato incluya el tiempo de conexión:

```
    log_format mysql '$remote_addr -> :$server_port -> $upstream_addr '
                     'estado=$status duracion=$session_time s '
                     'conexion=$upstream_connect_time s';
```

- `$upstream_addr` lista todos los nodos probados, separados por coma, cuando hubo reintento.
- `$upstream_connect_time` es el tiempo que tardó la conexión a cada nodo;  significa que no logró conectar.
- Atención al **espacio antes de la comilla** en la segunda línea (ver "Problemas comunes").

### 2.3 Validar y aplicar

```bash
docker run --rm --network proyecto-st_mysql_net \
  -v "$PWD/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
  nginx:1.27 nginx -t 2>&1 | tail -2

docker compose up -d --force-recreate nginx-lb
docker compose ps
```

- `nginx -t` valida la sintaxis. Se ejecuta **dentro de la red del proyecto** para que se resuelvan los nombres de los nodos. Debe decir `test is successful`.
- `-force-recreate` aplica el cambio: NGINX solo lee su configuración al arrancar.

### 2.4 Línea base (todo sano)

```bash
docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3308 -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT @@server_id"' 2>/dev/null
docker logs nginx-lb 2>&1 | tail -1
```

Línea normal del log:

```
172.18.0.2 -> :3308 -> 172.18.0.3:3306 estado=200 duracion=0.008 s conexion=0.000 s
```

- Una sola IP y `conexion=0.000 s`: el nodo respondió al instante. Es la referencia contra la que se compara la caída.

## Paso 3. Simular la caída de slave1 (35 conexiones, una por segundo)

Terminal A (log en vivo):

```bash
docker logs -f --tail 0 nginx-lb
```

Terminal B:

```bash
docker stop mysql-slave1
t0=$(date +%s)
for i in $(seq 1 35); do
  s=$(date +%s.%N)
  r=$(docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3308 -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT @@server_id"' 2>&1 | tail -1)
  e=$(date +%s.%N)
  printf "t=%2ss  nodo=%s  tardó=%.2fs\n" $(( $(date +%s) - t0 )) "$r" "$(awk "BEGIN{print $e-$s}")"
  sleep 1
done
docker logs nginx-lb 2>&1 | tail -40
```

- `docker stop` simula la caída.
- Cada vuelta abre una conexión nueva y mide cuánto tarda. `t` son los segundos desde que se paró slave1.
- La terminal A muestra el log de NGINX al cerrarse cada conexión.

## Paso 4. Recuperación de slave1

Con slave1 aún apagado:

```bash
docker start mysql-slave1
t0=$(date +%s)
for i in $(seq 1 60); do
  s=$(date +%s.%N)
  r=$(docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3308 -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT @@server_id"' 2>&1 | tail -1)
  e=$(date +%s.%N)
  h=$(docker inspect -f '{{.State.Health.Status}}' mysql-slave1)
  printf "t=%2ss  nodo=%s  tardó=%.2fs  slave1=%s\n" $(( $(date +%s) - t0 )) "$r" "$(awk "BEGIN{print $e-$s}")" "$h"
  sleep 1
done

docker inspect -f '{{.Name}} {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' mysql-slave1 mysql-slave2
./scripts/verify-replication.sh
```

- La columna `slave1=` muestra el estado de salud que reporta **Docker**, para compararlo con el momento en que **NGINX** le vuelve a mandar tráfico.
- Se confirma que slave1 conserva su IP y que `verify-replication.sh` da `OK`.

## Paso 5. Prueba automatizada: caída + escrituras + recuperación

Se creó `scripts/test-fase4.sh`. Apaga slave1, espera a que NGINX lo excluya, **escribe 7 transacciones por el 3307 con slave1 caído**, lo enciende **durante la exclusión** y compara filas y GTID al final. Una lectura por segundo se guarda en `/tmp/lecturas-fase4.log`.

```bash
cd ~/Proyecto-ST
cat > scripts/test-fase4.sh <<'FIN'
#!/bin/bash
# Fase 4: caída de slave1 + escrituras durante la caída + recuperación
cd "$(dirname "$0")/.." || exit 1

q() { docker exec mysql-master sh -c "mysql -h nginx-lb -P $1 -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -N -B -e \"$2\"" 2>&1 | grep -v "Using a password"; }
rel() { echo $(( $(date +%s) - T0 )); }
excl() { docker logs nginx-lb 2>&1 | grep -c "temporarily disabled"; }

echo "== 0. Estado inicial =="
./scripts/verify-replication.sh | grep -E "GTID:|RESULTADO"

N0=$(excl)
T0=$(date +%s)
LOG=/tmp/lecturas-fase4.log
echo "t nodo tardo_s" > $LOG
(
  while true; do
    s=$(date +%s.%N)
    r=$(q 3308 "SELECT @@server_id")
    e=$(date +%s.%N)
    printf "%d %s %.2f\n" $(( $(date +%s) - T0 )) "$r" "$(awk "BEGIN{print $e-$s}")"
    sleep 1
  done
) >> $LOG &
LOOP=$!
trap 'kill $LOOP 2>/dev/null' EXIT

sleep 3
echo; echo "== 1. Caída de slave1 =="
echo "[t=$(rel)s] Apagando slave1"
docker stop mysql-slave1 >/dev/null
for i in $(seq 1 45); do
  [ "$(excl)" -gt "$N0" ] && break
  sleep 1
done
echo "[t=$(rel)s] NGINX excluyó a slave1 (temporarily disabled)"

echo; echo "== 2. Escrituras con slave1 caído =="
q 3307 "CREATE DATABASE IF NOT EXISTS prueba_fase4"
q 3307 "CREATE TABLE prueba_fase4.t (id INT AUTO_INCREMENT PRIMARY KEY, txt VARCHAR(50))"
for i in 1 2 3 4 5; do q 3307 "INSERT INTO prueba_fase4.t (txt) VALUES ('fila $i')"; done
echo "[t=$(rel)s] 7 transacciones escritas en el maestro"
echo "GTID maestro: $(q 3307 'SELECT @@global.gtid_executed' | tr -d '\n')"

echo; echo "== 3. Recuperación de slave1 =="
TSTART=$(rel)
echo "[t=${TSTART}s] Encendiendo slave1"
docker start mysql-slave1 >/dev/null
for i in $(seq 1 40); do
  awk -v ts=$TSTART 'NR>1 && $1>=ts && $2==2 {f=1} END{exit !f}' $LOG && break
  sleep 1
done
TBACK=$(awk -v ts=$TSTART 'NR>1 && $1>=ts && $2==2 {print $1; exit}' $LOG)
if [ -n "$TBACK" ]; then
  echo "[t=${TBACK}s] Primera lectura servida por slave1 -> tardó $((TBACK-TSTART)) s en volver a recibir tráfico"
else
  echo "slave1 NO volvió a recibir tráfico en 40 s"
fi

sleep 10
echo; echo "== 4. Verificación de datos y replicación =="
./scripts/verify-replication.sh
for n in mysql-master mysql-slave1 mysql-slave2; do
  echo -n "$n filas: "
  docker exec $n sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT COUNT(*) FROM prueba_fase4.t"' 2>/dev/null
done

echo; echo "== 5. Limpieza =="
q 3307 "DROP DATABASE prueba_fase4"
sleep 3
./scripts/verify-replication.sh | grep -E "GTID:|RESULTADO"

echo; echo "== Lecturas lentas (>1 s) durante la prueba =="
awk 'NR>1 && $3>1' $LOG
echo; echo "Log completo de lecturas en $LOG"
FIN
chmod +x scripts/test-fase4.sh

./scripts/test-fase4.sh 2>&1 | tee /tmp/fase4-resultado.txt
```

- Una lectura por segundo corre en segundo plano durante toda la prueba y se guarda con su tiempo.
- Las escrituras van por el **3307** (maestro). Las lecturas, por el **3308**.
- Se enciende slave1 **inmediatamente después** de la exclusión para medir el peor caso de reincorporación.
- Al final se comparan filas (`COUNT(*)`) en los tres nodos y se corre el verificador de GTID.
- La limpieza (`DROP DATABASE`) se replica a los esclavos.

## Paso 6. Prueba en vivo con colores

Se creó `scripts/test-fase4-vivo.sh`: hace lo mismo que el anterior, pero muestra en pantalla, segundo a segundo, cada lectura (con el nodo que respondió, el tiempo y el estado del contenedor), cada evento de NGINX traducido (timeout, sin ruta, nodo excluido, reintento) y un resumen cada 10 lecturas. La salida queda sin colores en `/tmp/fase4-vivo.txt`. Si se interrumpe con `Ctrl+C`, vuelve a encender slave1 antes de salir.

```bash
cd ~/Proyecto-ST
cat > scripts/test-fase4-vivo.sh <<'FIN'
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
FIN
chmod +x scripts/test-fase4-vivo.sh

./scripts/test-fase4-vivo.sh
```

- El proceso `watcher` lee el log de NGINX y traduce cada `[error]`/`[warn]` a un mensaje claro, sustituyendo las IPs por `slave1`/`slave2`.
- El proceso `reads` hace una lectura por segundo y muestra nodo, tiempo y estado del contenedor `slave1` según Docker.
- Las banderas en `/tmp/f4_*` coordinan los procesos (por ejemplo, saber cuándo ya se excluyó el nodo o cuándo volvió).

---

# Resultados de las pruebas de caída

## Cómo leer el log de NGINX

Línea de una conexión normal:

```
172.18.0.2 -> :3308 -> 172.18.0.4:3306 estado=200 duracion=0.008 s conexion=0.000 s
```

Línea de una conexión que chocó con el nodo caído:

```
172.18.0.2 -> :3308 -> 172.18.0.3:3306, 172.18.0.4:3306 estado=200 duracion=5.016 s conexion=-, 0.001 s
```

- Dos IPs separadas por coma: NGINX probó **slave1 (`.3`)**, falló y reintentó con **slave2 (`.4`)**.
- `conexion=-, 0.001 s`: el primer intento nunca conectó; el segundo tardó un milisegundo.
- `estado=200`: el cliente recibió respuesta. `duracion=5.016 s` es el tiempo perdido esperando a slave1.

Mensajes del log de errores:

| Mensaje | Qué significa |
| --- | --- |
| `upstream timed out (110: Connection timed out)` | El nodo no respondió dentro de `proxy_connect_timeout` (5 s). Cuenta como fallo |
| `connect() failed (113: No route to host)` | El destino ya no existe en la red de Docker. Falla más rápido que un timeout. Cuenta como fallo |
| `connect() failed (111: Connection refused)` | El nodo existe pero nadie escucha en el puerto (por ejemplo, MySQL arrancando). Falla casi al instante. Cuenta como fallo |
| `upstream server temporarily disabled` | **Momento exacto en que NGINX excluye al nodo** durante `fail_timeout` (10 s) |

## Prueba A: caída con 35 conexiones (una por segundo)

Ninguna conexión falló; todas respondieron `nodo=3` (slave2). Hubo 4 conexiones lentas de 35:

| Segundo | Duración | Evento en el log |
| --- | --- | --- |
| 6 | 5.12 s | `upstream timed out`: primer fallo contado |
| 12 | 4.23 s | `No route to host` + **`temporarily disabled`**: slave1 excluido |
| 28 | 3.17 s | `No route to host` + `temporarily disabled`: NGINX lo prueba de nuevo y lo vuelve a excluir |
| 43 | 3.18 s | Igual que el anterior |

Lectura de los datos:

- **Detección:** unos 12 s tras apagar slave1, con **dos** clientes afectados (t=6 y t=12).
- **Sondeo posterior:** mientras el nodo sigue caído, un cliente "sacrificado" cada ~15 s (la exclusión de 10 s más el tiempo hasta que una conexión real cae sobre el nodo y el intento fallido de ~3 s).
- El primer fallo esperó los 5 s completos; los siguientes fallaron antes (~3 s) con `No route to host`. *Hipótesis no verificada:* al principio el sistema espera en vano; pasado un tiempo, el kernel reconoce que el destino ya no existe.

## Prueba B: recuperación con slave1 apagado desde hacía tiempo

| Medición | Resultado |
| --- | --- |
| Primera respuesta de slave1 tras `docker start` | **t=1 s** |
| Estado de salud en Docker en ese momento | `starting` |
| Docker lo marcó `healthy` | t=10 s |
| Errores o lecturas lentas | Ninguno (todas ~0.1 s) |
| IP de slave1 | `172.18.0.3` (sin cambios) |
| `verify-replication.sh` | `OK` en ambos esclavos |

**Hallazgo clave:** NGINX no mira el `healthcheck` de Docker. Slave1 recibió tráfico 9 s antes de que Docker lo marcara `healthy`. Son mecanismos independientes: el de Docker alimenta el `depends_on` al arrancar, y el de NGINX decide el reparto en tiempo real. Aquí la recuperación fue inmediata porque la última exclusión ya había vencido (*explicación probable, sin el log de esa corrida para confirmarla*).

## Prueba C: caída + 7 escrituras + recuperación (`test-fase4.sh`)

| Medición | Resultado |
| --- | --- |
| Apagado de slave1 → exclusión | t=3 → t=11 (**~8 s**) |
| Lecturas lentas | 1 de 31 (5.11 s), **0 errores** |
| Escrituras con slave1 caído | 7 transacciones (GTID `1-7` → `1-14`) |
| Encendido de slave1 → primera lectura suya | t=12 → t=23 (**11 s**) |
| Filas al final | 5 / 5 / 5 en maestro, slave1 y slave2 |
| Replicación al final | `OK` en ambos, GTID `1-15` tras la limpieza |

Se encendió slave1 en plena exclusión de 10 s, por lo que NGINX esperó a que venciera antes de volver a usarlo.

## Prueba D: la misma prueba en vivo (`test-fase4-vivo.sh`)

Cronología observada:

| t | Evento |
| --- | --- |
| 6 s | `docker stop mysql-slave1` (el apagado tardó 2 s) |
| 7 s | NGINX: conexión **rechazada** por slave1 (0.012 s). Primer fallo contado; retry a slave2 |
| 14 s | NGINX: **timeout** de 5 s con slave1 → **slave1 EXCLUIDO**. Lectura lenta de 5.09 s |
| 15–28 s | Solo responde slave2, todo ~0.1 s |
| 21–28 s | 7 escrituras en el maestro (GTID `1-15` → `1-22`) |
| 29 s | `docker start mysql-slave1` |
| 30 s | NGINX prueba a slave1 con MySQL aún arrancando: **rechazada** → **vuelve a excluirlo** 10 s. Lectura lenta de 4.18 s |
| 40 s | Docker marca slave1 `healthy` |
| 43 s | ★ slave1 vuelve a recibir tráfico |

Resumen de la corrida:

| Medición | Resultado |
| --- | --- |
| `docker stop` | 2 s |
| Detección (apagado → exclusión) | **8 s** |
| Recuperación (`docker start` → primera lectura de slave1) | **14 s** |
| Lecturas totales | 39 (slave1 = 8, slave2 = 31) |
| Lecturas lentas | 2 (5.09 s y 4.18 s) |
| Errores | **0** |
| Filas finales | 5 / 5 / 5 |
| Replicación al final | `OK` en ambos esclavos |

## Comparación de los tiempos de recuperación

| Prueba | Tiempo | Qué pasó |
| --- | --- | --- |
| B | ~1 s | Slave1 llevaba tiempo apagado: la exclusión ya había vencido y la primera prueba cayó con MySQL escuchando |
| C | 11 s | Se encendió durante la exclusión: NGINX esperó a que venciera |
| D | 14 s | Igual que C, pero además la primera prueba cayó **antes** de que MySQL escuchara y lo excluyó otros 10 s |

**El tiempo de recuperación no es fijo:** va de ~1 s hasta `fail_timeout` más el arranque de MySQL (unos 10 a 15 s), según cuándo caiga la primera conexión de prueba.

## Conclusiones de la prueba

1. **Cero errores visibles para el cliente.** NGINX reintenta con el siguiente nodo dentro de la misma conexión.
2. **El costo es latencia, no errores:** entre 3 y 5 s para los clientes que chocan con el nodo caído, y un cliente sacrificado cada ~15 s mientras siga caído.
3. **La detección depende del tráfico.** Con health checks pasivos, sin clientes no hay detección.
4. **La replicación por GTID recupera lo perdido.** Las escrituras hechas con slave1 caído aparecieron en slave1 al volver, sin intervención manual.
5. **El tiempo de reincorporación está gobernado por `fail_timeout`**, no por la velocidad de arranque de MySQL.

## Limitaciones del mecanismo (documentar en el informe)

- **Es un chequeo TCP:** solo sabe que el puerto 3306 acepta conexiones. No sabe si el esclavo tiene la replicación rota (`Slave_SQL_Running: No`) o va atrasado. En ese caso NGINX lo seguiría considerando sano y le mandaría lecturas con datos viejos. **Este escenario no se probó en esta fase**; la conclusión se deduce de cómo funciona el chequeo TCP.
- **No hay detección activa:** la directiva `health_check` es exclusiva de NGINX Plus.
- **No hay failover del maestro:** si cae el maestro, las lecturas siguen pero no se puede escribir. Está fuera del alcance de esta fase.
- **Las mediciones son de una máquina y de pocas corridas.** Los tiempos varían entre ejecuciones, como muestra la tabla de recuperación.

---

# Problemas comunes y solución

## 1. `docker compose restart` falla con `no such file or directory` al montar `my.cnf`

- **Síntoma:** tras editar los `my.cnf` con `sed -i` y ejecutar `docker compose restart mysql-slave1 mysql-slave2`: `error mounting ... to rootfs at "/etc/mysql/conf.d/my.cnf": ... no such file or directory`.
- **Causa:** `sed -i` no edita el archivo en su lugar: crea uno nuevo y reemplaza al viejo. El contenedor tenía montado el archivo original (bind mount de un solo archivo), que ya no existe.
- **Solución:** recrear el contenedor en lugar de reiniciarlo. Los datos viven en el volumen y se conservan.

```bash
docker compose up -d --force-recreate mysql-slave1 mysql-slave2
```

- **Regla:** si se edita un `my.cnf` o el `nginx.conf` con `sed -i` (o con un editor que reemplaza el archivo, como a veces hace `vim`), usar `up -d --force-recreate <servicio>`.

## 2. Falta de espacio en el `log_format`: `duracion=0.009 sconexion=0.000 s`

- **Síntoma:** la `s` de "duracion" aparecía pegada a "conexion" en el log.
- **Causa:** la segunda línea del `log_format` terminaba en `...$session_time s'` sin espacio antes de la comilla de cierre; NGINX concatena las dos cadenas tal cual.
- **Solución:** añadir el espacio (`...$session_time s '`), validar con `nginx -t` y recrear el contenedor.

```bash
docker run --rm --network proyecto-st_mysql_net \
  -v "$PWD/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
  nginx:1.27 nginx -t 2>&1 | tail -2
docker compose up -d --force-recreate nginx-lb
```

- No rompía nada, pero los logs van a la documentación y se leen mejor limpios.

## 3. Ningún archivo del repo crea el usuario `replicador`

- **Síntoma:** en una máquina nueva, `docker compose up -d` deja los esclavos sin poder replicar.
- **Causa:** en la Fase 1 el usuario se creó a mano con `docker exec`, y el README solo dice `docker compose up -d`.
- **Solución:** levantar primero el maestro, crear el usuario y luego el resto (ver "Preparación del entorno", paso 3).
- **Recomendación para el equipo:** automatizarlo con un script de inicialización del maestro (`mysql/master-init/`, montado en `/docker-entrypoint-initdb.d`) para que el prototipo funcione con un solo comando.

## 4. `super_read_only=1` en los `my.cnf` de los esclavos al primer arranque

- **Síntoma esperado:** en un volumen vacío, la imagen de MySQL necesita escribir para inicializarse, y con `super_read_only=1` activo el primer arranque puede fallar.
- **Causa:** en el proyecto original se añadió después de que los esclavos ya existían.
- **Solución:** quitar la línea antes del primer arranque y reactivarla al final, recreando los esclavos (ver "Preparación del entorno", pasos 2 y 4).
- **Nota:** en esta sesión se aplicó el procedimiento preventivo y el arranque funcionó; el fallo en sí no se reprodujo.

## 5. `docker inspect` muestra `invalid IP` para slave1

- **Síntoma:** con slave1 detenido, `docker inspect -f '{{.Name}} {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' mysql-slave1` devolvía `invalid IP`.
- **Causa:** un contenedor detenido no tiene IP en la red. No es un error: confirma que slave1 sigue apagado.
- **Solución:** anotar las IPs **antes** de la prueba (paso 2.1). Al reiniciar, slave1 conservó `172.18.0.3`.

## 6. Primera lectura lenta mucho antes de la exclusión, o fallo "demasiado rápido"

- **Síntoma:** en la Prueba D, el primer fallo (t=7) fue una conexión rechazada en 0.012 s, y la lectura lenta llegó recién en t=14.
- **Causa:** al apagarse el contenedor, MySQL cierra el puerto antes de que el contenedor desaparezca de la red. Ese primer rechazo es rápido pero **cuenta como fallo**. El segundo, ya con el contenedor fuera de la red, espera el timeout completo.
- **Solución:** no es un fallo del sistema. Tenerlo presente al interpretar los tiempos: el tipo de error (`refused`, `No route to host` o `timed out`) cambia cuánto tarda cada intento fallido.

## 7. Interpretación de los ciclos: 10 s vs ~15 s

- **Malentendido:** se esperaba un cliente sacrificado cada 10 s (el `fail_timeout`).
- **Lo observado:** el patrón se repitió cada ~15 s.
- **Explicación:** la exclusión dura 10 s, pero al vencer el nodo solo se prueba cuando una conexión real cae sobre él, y el propio intento fallido tarda ~3 s.
- **Qué hacer:** documentar el periodo como "~15 s observados", no como "10 s".

## 8. La recuperación tardó 1 s, 11 s y 14 s según la prueba

- **Síntoma:** tres tiempos de reincorporación muy distintos con el mismo procedimiento.
- **Causa:** depende de **cuándo** se enciende slave1 respecto a la exclusión de 10 s y de si la primera prueba de NGINX cae antes o después de que MySQL escuche.
- **Solución:** reportar un rango, no un valor único (ver "Comparación de los tiempos de recuperación").

## 9. Detalles que no son errores

- Los mensajes `10-listen-on-ipv6...` y `20-envsubst...` al ejecutar `nginx -t` son scripts de arranque de la imagen y no afectan.
- `docker compose ps` muestra `Up` (sin `healthy`) para `nginx-lb`: la imagen no tiene healthcheck definido.
- El log de stream se escribe **al cerrar** la conexión, no al abrirla.
- Un `}` pegado antes de una línea de salida en la terminal es un residuo del copiado, no del script.

---

# Reglas de seguridad del proyecto

- Nunca usar `docker compose down -v`: borra también el volumen del maestro.
- Trabajar siempre desde `~/Proyecto-ST`, no desde `/mnt/c`.
- Los scripts de `mysql/slave-init/` solo corren con el volumen vacío.
- Si se edita un archivo montado con `sed -i`, recrear el servicio con `-force-recreate`.

---

# Checklist de finalización

- [x]  Explicado el health check TCP vs HTTP y pasivo vs activo
- [x]  Identificado el mecanismo disponible en `nginx:1.27` (pasivo: `max_fails`, `fail_timeout`)
- [x]  Log de NGINX ampliado con el tiempo de conexión a cada nodo
- [x]  Simulada la caída de un esclavo con `docker stop`
- [x]  Verificado que NGINX redirige solo a los nodos disponibles (0 errores)
- [x]  Verificado que el nodo vuelve a recibir tráfico al recuperarse
- [x]  Verificado que las escrituras hechas durante la caída llegan al esclavo por GTID (5/5/5 filas)
- [x]  Tiempos de detección y recuperación medidos en cuatro corridas
- [x]  Scripts reproducibles: `scripts/test-fase4.sh` y `scripts/test-fase4-vivo.sh`

|  |  |  |
| --- | --- | --- |
|  |  |  |
|  |  |  |
|  |  |  |
|  |  |  |
|  |  |  |
|  |  |  |
|  |  |  |
|  |  |  |
|  |  |  |
|  |  |  |
|  |  |  |