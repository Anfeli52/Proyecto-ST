# Fase 5 — Sysbench: Preparación y pruebas de solo lectura

## Resumen

En esta fase se midió el rendimiento de lectura del sistema con **Sysbench**, una herramienta que genera carga artificial sobre una base de datos y reporta cuántas transacciones atiende (TPS) y cuánto tarda cada una (latencia).

Qué se preparó:

- Un contenedor propio de Sysbench (`severalnines/sysbench`, versión 1.0.17), agregado al `docker-compose.yml` como servicio `sysbench` bajo el perfil `bench`. No se levanta con `docker compose up -d`; solo se ejecuta cuando se invoca con `docker compose run --rm sysbench ...`.
- Un dataset de prueba: la base `sbtest` con la tabla `sbtest1` de **1.000.000 de filas**, escrita en el maestro y replicada a los dos esclavos.
- Un usuario dedicado `sbtest` con autenticación `mysql_native_password` (ver "Problemas comunes").

Qué se probó:

- **Benchmark de solo lectura** (`oltp_read_only`): 10 hilos, 60 segundos, apuntando al puerto de lectura de NGINX (3308).
- **Comparación** contra una conexión directa a un solo nodo (`mysql-slave1:3306`) y contra un solo esclavo detrás de NGINX, para aislar el costo del proxy.
- **Prueba de carga mayor** con 64 y 128 hilos (30 s cada una) para ver cómo se comporta el sistema al saturarse.

Por qué: las pruebas de rendimiento dan evidencia medible de cómo se comporta el sistema, no solo de que funciona. Cada número se compara bajo los mismos parámetros y en el mismo equipo para que la comparación sea válida.

### Conceptos clave

- **OLTP (Online Transaction Processing):** carga típica de una aplicación web, con muchas consultas pequeñas y rápidas. El script `oltp_read_only` ejecuta por transacción 10 `SELECT` por clave primaria, consultas por rango, `SUM`, `ORDER BY` y `DISTINCT`.
- **TPS:** transacciones completas por segundo. Más alto es mejor.
- **QPS:** consultas por segundo. Es mayor que el TPS porque cada transacción contiene varias consultas.
- **Latencia:** tiempo que tarda una transacción. Se reporta el promedio y el **percentil 95 (p95)**: el valor que no supera el 95 % de las transacciones. Más bajo es mejor.
- **Por qué el prepare va por el puerto 3307:** NGINX trabaja en capa 4 (TCP) y no distingue un `SELECT` de un `INSERT`, por eso hay dos puertos. El 3307 va al maestro (escrituras) y el 3308 a los esclavos (lecturas). Los esclavos tienen `super_read_only=1`, así que el `prepare` (que crea tablas e inserta) debe ir al maestro; la replicación GTID copia luego los datos a los esclavos.

---

## Entorno de las pruebas

- Docker corre directamente sobre Linux, sin máquina virtual. Los contenedores usan **la CPU (12 núcleos), RAM y disco del PC host**, sin límites configurados.
- MySQL 8.0.46 (imagen `mysql:8.0`), NGINX 1.27, Sysbench 1.0.17.
- Red `proyecto-st_mysql_net` (bridge virtual dentro del mismo equipo).

---

## Comandos ejecutados, en orden

### A. Preparación del entorno (Fases 1 a 4)

#### 1. Generar el archivo `.env`

```bash
cat > .env <<EOF
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 24)
MYSQL_REPL_USER=replicador
MYSQL_REPL_PASSWORD=$(openssl rand -hex 12)
EOF
chmod 600 .env
```

- `openssl rand -hex N`: genera N bytes aleatorios en hexadecimal; sirve para contraseñas.
- `chmod 600`: solo el dueño puede leer y escribir el archivo.

#### 2. Levantar los contenedores

```bash
docker compose up -d
```

- `up`: crea e inicia los servicios. `-d`: en segundo plano.

#### 3. Crear el usuario de replicación en el maestro (paso manual de la Fase 1)

```bash
docker exec mysql-master sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER IF NOT EXISTS \"$MYSQL_REPL_USER\"@\"%\" IDENTIFIED BY \"$MYSQL_REPL_PASSWORD\"; GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO \"$MYSQL_REPL_USER\"@\"%\";"'
```

- `docker exec <contenedor> sh -c '...'`: ejecuta un comando dentro de un contenedor en marcha.
- `CREATE USER IF NOT EXISTS ... @"%"`: crea el usuario si no existe, accesible desde cualquier host de la red.
- `GRANT REPLICATION SLAVE, REPLICATION CLIENT`: permisos mínimos para replicar y consultar el estado.

#### 4. Reiniciar la replicación en los esclavos y verificarla

```bash
docker exec mysql-slave1 sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "STOP SLAVE; START SLAVE;"'
docker exec mysql-slave2 sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "STOP SLAVE; START SLAVE;"'
./scripts/verify-replication.sh
```

- `STOP SLAVE; START SLAVE;`: reinicia los hilos de replicación para que reintenten conectarse de inmediato.
- `verify-replication.sh`: comprueba `Slave_IO_Running`, `Slave_SQL_Running`, el retraso y que los GTID del maestro estén en cada esclavo. Debe terminar con `RESULTADO: OK` en ambos.

### B. Paso 1 — Instalar Sysbench

```bash
docker pull -q severalnines/sysbench
docker run --rm --network proyecto-st_mysql_net severalnines/sysbench sysbench --version
```

- `docker pull -q`: descarga la imagen en silencio.
- `docker run --rm`: crea un contenedor temporal y lo borra al terminar.
- `--network proyecto-st_mysql_net`: lo conecta a la red del proyecto para resolver `nginx-lb`, `mysql-master`, etc.
- Resultado: `sysbench 1.0.17`.

Después se agregó el servicio al `docker-compose.yml`:

```yaml
  sysbench:
    image: severalnines/sysbench
    container_name: sysbench
    profiles: ["bench"]
    entrypoint: ["sysbench"]
    depends_on:
      nginx-lb:
        condition: service_started
    environment:
      SYSBENCH_PASSWORD: ${SYSBENCH_PASSWORD}
    networks:
      - mysql_net
```

- `profiles: ["bench"]`: el servicio solo se levanta cuando se pide explícitamente.
- `entrypoint: ["sysbench"]`: lo que se escribe después del nombre del servicio son los argumentos de Sysbench.

Verificación:

```bash
docker compose config -q
docker compose run --rm sysbench --version
```

- `config -q`: valida la sintaxis del compose sin imprimirlo.

### C. Paso 2 — Preparar el dataset

#### Variable de contraseña y usuario dedicado

```bash
echo "SYSBENCH_PASSWORD=$(openssl rand -hex 12)" >> .env
set -a; . ./.env; set +a
docker exec mysql-master sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \"CREATE USER IF NOT EXISTS 'sbtest'@'%' IDENTIFIED WITH mysql_native_password BY '$SYSBENCH_PASSWORD'; GRANT ALL ON sbtest.* TO 'sbtest'@'%';\""
docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3307 -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS sbtest"'
```

- `set -a; . ./.env; set +a`: carga las variables del `.env` en la shell y las exporta.
- `IDENTIFIED WITH mysql_native_password`: método de autenticación que el cliente de Sysbench soporta.
- `GRANT ALL ON sbtest.*`: permisos solo sobre la base de pruebas.
- `-h nginx-lb -P 3307`: se conecta a NGINX por el puerto de escritura (maestro).

#### prepare

```bash
docker compose run --rm sysbench oltp_read_only \
  --mysql-host=nginx-lb --mysql-port=3307 \
  --mysql-user=sbtest --mysql-password=$SYSBENCH_PASSWORD \
  --mysql-db=sbtest --tables=1 --table-size=1000000 prepare
```

| Parámetro | Qué hace |
|---|---|
| `oltp_read_only` | Script de prueba de solo lectura (define la tabla y las consultas). |
| `--mysql-host` / `--mysql-port` | Servidor al que conectarse. Aquí NGINX, puerto de escritura 3307. |
| `--mysql-user` / `--mysql-password` | Credenciales del usuario `sbtest`. |
| `--mysql-db` | Base de datos de trabajo. |
| `--tables=1` | Cantidad de tablas a crear (`sbtest1`). |
| `--table-size=1000000` | Filas por tabla: 1.000.000. |
| `prepare` | Acción: crea la tabla, inserta las filas aleatorias y crea el índice secundario sobre `k`. Las otras acciones son `run` y `cleanup`. |

Duró unos 18 segundos.

#### Verificar que el dataset llegó a los tres nodos

```bash
./scripts/verify-replication.sh | grep -E "RESULTADO|GTID al día"
for n in mysql-master mysql-slave1 mysql-slave2; do
  docker exec $n sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT COUNT(*) FROM sbtest.sbtest1"'
done
```

- `-N -B`: salida sin encabezados y en formato por lotes (solo el valor).
- Resultado: **1000000** en el maestro, slave1 y slave2, con GTID al día.

### D. Paso 3 — Benchmark de solo lectura por NGINX (3308)

Durante la sesión se usó un script temporal que hacía un calentamiento de 10 s, la prueba oficial de 60 s y, a mitad de la prueba, contaba las conexiones de `sbtest` en cada esclavo. Esa lógica quedó consolidada en el script del repositorio `scripts/benchmark-lectura.sh` (ver sección E).

Comando de Sysbench de la prueba principal:

```bash
docker compose run --rm -T sysbench oltp_read_only \
  --mysql-host=nginx-lb --mysql-port=3308 \
  --mysql-user=sbtest --mysql-password=$SYSBENCH_PASSWORD \
  --mysql-db=sbtest --tables=1 --table-size=1000000 \
  --threads=10 --time=60 --report-interval=10 run
```

| Parámetro | Qué hace |
|---|---|
| `--mysql-port=3308` | Puerto de lectura de NGINX: reparte entre slave1 y slave2 con `least_conn`. |
| `--threads=10` | Clientes simultáneos: 10 hilos, cada uno con su propia conexión. |
| `--time=60` | Duración de la prueba en segundos. |
| `--report-interval=10` | Imprime TPS, QPS y latencia cada 10 s. |
| `run` | Acción: ejecuta la carga. |
| `-T` (de `docker compose run`) | Desactiva la terminal interactiva, necesario para guardar la salida en un archivo. |

Conexiones contadas durante la prueba:

```bash
docker exec mysql-slave1 sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT COUNT(*) FROM information_schema.processlist WHERE user=\"sbtest\""'
```

Resultado: **5 conexiones en slave1 y 5 en slave2**, es decir, `least_conn` reparte simétricamente.

### E. Paso 4 — Comparación contra un solo nodo y pruebas de mayor carga

Para repetir la comparación con un solo comando se creó `scripts/benchmark-lectura.sh`:

```bash
./scripts/benchmark-lectura.sh              # 10 hilos, 60 s por prueba
./scripts/benchmark-lectura.sh -t 64 -d 30  # otra carga
./scripts/benchmark-lectura.sh -u           # añade "1 esclavo vía NGINX"
```

| Opción | Qué hace |
|---|---|
| `-t HILOS` | Hilos (conexiones simultáneas). Por defecto 10. |
| `-d SEGUNDOS` | Duración de cada prueba. Por defecto 60. |
| `-u` | Incluye la medición "un solo esclavo vía NGINX". |

Qué hace el script:

1. Carga el `.env` y comprueba que los cuatro contenedores corran.
2. Verifica que el dataset tenga **1.000.000 de filas en los tres nodos** (si no, aborta e indica ejecutar el `prepare`).
3. Hace un calentamiento de 10 s que no se reporta.
4. Mide con los mismos parámetros: **vía NGINX** (`nginx-lb:3308`, 2 esclavos) y **directo a un nodo** (`mysql-slave1:3306`).
5. Con `-u`, levanta un NGINX temporal que apunta solo a slave1, lo mide y lo elimina al terminar (`docker run -d --rm`, configuración montada en solo lectura).
6. Imprime una tabla con TPS, QPS, latencia promedio, p95, máxima y errores.

Ejemplo de salida (10 hilos, 10 s por prueba, con `-u`):

```
Destino                                 TPS        QPS   avg(ms)   p95(ms)   max(ms)    err
--------------------------------------------------------------------------------------------
Vía NGINX (2 esclavos)              4671.46   74743.38      2.14      3.02      8.75      0
Directo a 1 esclavo (slave1)        7859.72  125755.45      1.27      1.89      7.27      0
Vía NGINX (1 esclavo)               4795.49   76727.88      2.08      2.91     10.72      0
```

La configuración del NGINX temporal que usa `-u`:

```nginx
worker_processes auto;
events { worker_connections 4096; }
stream {
  upstream s1 { server mysql-slave1:3306; }
  server { listen 3308; proxy_pass s1; }
}
```

Los resultados de la sección siguiente se obtuvieron en la sesión original con las mismas pruebas: 10 hilos (60 s) y, además, 64 y 128 hilos (30 s) contra los tres destinos. Para reproducirlos: `./scripts/benchmark-lectura.sh -u` (10 hilos), `-t 64 -d 30 -u` y `-t 128 -d 30 -u`.

Para conocer los recursos del equipo donde se midió:

```bash
nproc
```

- `nproc`: cantidad de núcleos del equipo (12).

---

## Resultados

### Prueba principal: solo lectura, 10 hilos, 60 s, vía NGINX (puerto 3308)

| Métrica | Valor |
|---|---|
| Transacciones totales | 310.469 |
| **TPS** | **5174,14** |
| QPS | 82.786,19 |
| Latencia mínima | 0,76 ms |
| **Latencia promedio** | **1,93 ms** |
| **Latencia p95** | **2,52 ms** |
| Latencia máxima | 13,06 ms |
| Errores / reconexiones | 0 / 0 |
| Reparto de conexiones | 5 en slave1, 5 en slave2 |

### Comparación (0 errores en todas las pruebas)

| Hilos | Vía NGINX, 2 esclavos | Vía NGINX, 1 esclavo | Directo a 1 esclavo |
|---|---|---|---|
| 10 (60 s) | 5174 TPS · avg 1,93 ms · p95 2,52 ms | 4927 TPS · avg 2,03 ms · p95 2,76 ms | 8014 TPS · avg 1,25 ms · p95 1,82 ms |
| 64 (30 s) | 5136 TPS · avg 12,45 ms · p95 23,10 ms | 5358 TPS · avg 11,94 ms · p95 23,52 ms | 7791 TPS · avg 8,21 ms · p95 17,63 ms |
| 128 (30 s) | 4873 TPS · avg 26,25 ms · p95 48,34 ms | 4977 TPS · avg 25,70 ms · p95 53,85 ms | 7321 TPS · avg 17,47 ms · p95 39,65 ms |

### Interpretación

- **El balanceo reparte bien:** 5 y 5 conexiones, sin errores incluso con 128 hilos.
- **El proxy tiene un costo:** pasar por NGINX rinde alrededor de un 35 % menos TPS y más latencia que ir directo a un nodo. Es el precio normal de un balanceador de capa 4 (un salto de red extra y copiar los paquetes dos veces).
- **Dos esclavos no superaron a uno en este entorno:** la ruta por NGINX se quedó en ~5000 TPS con uno o con dos esclavos, y no cambió al subir los hilos. Esto es consistente con que el límite está en el camino por el proxy y no en MySQL. No se midió CPU por contenedor, así que es una hipótesis que encaja con los datos, no una causa demostrada.
- **Limitación del laboratorio:** todos los contenedores (MySQL, NGINX y Sysbench) comparten los mismos 12 núcleos del PC host. Un segundo esclavo no añade hardware, solo reparte el existente. El balanceo de lectura mejora el rendimiento cuando cada esclavo corre en hardware distinto y un solo nodo es el cuello de botella.
- **Más hilos no aumentan el TPS una vez saturado el servidor:** solo suben la latencia (en la conexión directa, el p95 pasó de 1,82 ms con 10 hilos a 39,65 ms con 128).
- Los valores absolutos dependen de la máquina y de la carga del momento. Lo válido es la comparación relativa, porque todas las pruebas usaron los mismos parámetros en el mismo equipo.

### Cuándo sí rinde el balanceo de lectura

- Esclavos en máquinas distintas, donde cada uno aporta CPU, RAM y disco propios.
- Cargas con muchas más lecturas que escrituras (catálogos, sitios web, reportes).
- Cuando un solo nodo ya está saturado.
- Cuando importa la disponibilidad: si un esclavo cae, NGINX lo retira del reparto y el servicio sigue (Fase 4).
- No ayuda en cargas de muchas escrituras (todas van al maestro) ni cuando se exige el dato más reciente (la replicación es asíncrona).

---

## Problemas comunes y solución

### 1. Los esclavos no arrancan: `ERROR 1290 ... running with the --super-read-only option`

- **Síntoma:** `docker compose up -d` termina con `dependency failed to start: container mysql-slave1 exited (1)` y el log muestra `ERROR 1290 (HY000) at line 1`.
- **Causa:** el `my.cnf` de los esclavos trae `super_read_only=1`. En el primer arranque, el entrypoint de la imagen usa un servidor temporal para su propia configuración inicial, y ese servidor ya está en modo solo lectura, así que falla antes de ejecutar el script de replicación.
- **Solución aplicada:** se inicializaron los esclavos sin `super_read_only` en el cnf y se activó al final con `SET PERSIST read_only=1; SET PERSIST super_read_only=1;` (queda guardado en el volumen y sobrevive a reinicios). Luego se revirtieron los archivos del repositorio para no modificar el trabajo de los demás; el entorno ya inicializado sigue funcionando con los archivos originales.
- **Importante:** si alguien recrea los volúmenes de los esclavos (`docker volume rm ...slave*_data` y `up`), el error reaparece. Hay que comentar `super_read_only=1` mientras se inicializa, o aplicar el arreglo en el repositorio.

### 2. Replicación en `Connecting`: `Access denied for user 'replicador'`

- **Síntoma:** `verify-replication.sh` da `Slave_IO_Running: Connecting` y `Last_IO_Error: ... Access denied for user 'replicador'@'172.19.0.x'`.
- **Causa:** el usuario `replicador` no existe en un maestro recién creado; en la Fase 1 se crea con un paso manual y ningún script lo hace.
- **Solución:** ejecutar el `CREATE USER` y el `GRANT` del apartado A.3 y luego `STOP SLAVE; START SLAVE;` en cada esclavo. Se debe repetir cada vez que se recree el volumen del maestro.

### 3. Sysbench no conecta: `error 2059: Authentication plugin 'caching_sha2_password' cannot be loaded`

- **Síntoma:** el `prepare` falla con `FATAL: unable to connect to MySQL server ... error 2059`.
- **Causa:** el cliente de Sysbench es de MariaDB y no soporta `caching_sha2_password`, el método de autenticación por defecto de MySQL 8.
- **Solución:** crear un usuario dedicado con `IDENTIFIED WITH mysql_native_password` en el maestro. La replicación lo copia a los esclavos. Su contraseña se guarda como `SYSBENCH_PASSWORD` en el `.env` y se pasa al servicio en el compose.

### 4. `Unknown MySQL server host 'nginx-lb --mysql-port=3308 --mysql-user=...'`

- **Síntoma:** Sysbench interpreta todos los parámetros como si fueran el nombre del host y falla con `error 2005`.
- **Causa:** en zsh, una variable usada sin comillas como `$ARGS` no se separa en palabras; se pasó como un único argumento gigante.
- **Solución:** guardar los argumentos en un array de bash (`A=(--mysql-host=... --mysql-port=...)`) y pasarlos como `"${A[@]}"`, ejecutando el script con `bash`. El script `scripts/benchmark-lectura.sh` ya lo hace así, por lo que se puede usar desde cualquier shell.

### 5. Errores de conexión de Sysbench en general

- Fuera de la red del proyecto los nombres (`nginx-lb`, `mysql-slave1`) no resuelven. Usar `docker compose run` o `--network proyecto-st_mysql_net`.
- Un puerto equivocado da resultados engañosos: el `prepare` solo puede ir al 3307 (maestro). Por el 3308 falla con `super-read-only`.
- Antes de medir, comprobar con `./scripts/verify-replication.sh` y con el `COUNT(*)` que los tres nodos tienen las 1.000.000 de filas.

### 6. Resultados que sorprenden

- **Mayor TPS directo que por NGINX:** es normal; ver la interpretación (costo del proxy y hardware compartido).
- **Latencia que se dispara al subir los hilos sin que suba el TPS:** es la saturación del servidor; los hilos extra solo hacen cola.
- **Un TPS que varía entre corridas:** depende de la carga del equipo en ese momento. Usar siempre un calentamiento y los mismos parámetros para comparar.

---

## Checklist de finalización

- [x] Sysbench instalado y funcionando en un contenedor propio (servicio `sysbench` en el compose)
- [x] Dataset de prueba preparado con la tabla oltp (1.000.000 de filas, verificado en los tres nodos)
- [x] Benchmark ejecutado: 10 hilos, 60 segundos, solo lectura, puerto de lectura de NGINX (3308)
- [x] TPS y latencia del benchmark de solo lectura registrados
- [x] Resultados comparados contra una conexión directa a un solo nodo (y contra un solo esclavo vía NGINX)
- [x] README actualizado con cómo preparar el dataset, correr el benchmark de lectura y el diagrama de arquitectura con el contenedor `sysbench`
- [x] Script `scripts/benchmark-lectura.sh` para repetir la comparación con un comando

---

## Archivos de la fase en el repositorio

| Archivo | Cambio |
|---|---|
| `docker-compose.yml` | Nuevo servicio `sysbench` (perfil `bench`) |
| `.env.example` | Nueva variable `SYSBENCH_PASSWORD` |
| `README.md` | Sección "Benchmark con Sysbench (Fase 5)", diagrama actualizado, tabla de variables y de fases |
| `scripts/benchmark-lectura.sh` | Script de benchmark y comparación |
| `docs/2 5 Fase 5 — Sysbench Preparación y pruebas de solo lectura.md` | Esta documentación |

Nota: la Fase 6 (lectura/escritura) probablemente reutilice el mismo dataset, por lo que no se ejecutó `cleanup` al terminar. Si no se necesita, se borra con la acción `cleanup` por el puerto 3307.
