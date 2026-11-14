# 2.6. Fase 6 — Sysbench: Pruebas mixtas y consolidación de métricas (Agudelo)

# Fase 6 — Sysbench: Pruebas mixtas y consolidación de métricas

## Resumen

En esta fase se midió el rendimiento del sistema completo con cargas que van más allá del solo lectura de la Fase 5: una carga mixta de lectura/escritura, una carga con un esclavo caído, y dos mediciones adicionales (retraso de replicación y tiempo de puesta al día). Después se consolidaron todas las métricas en una tabla comparativa y se redactaron conclusiones preliminares.

Qué se hizo:

- Un script reproducible, `scripts/benchmark-mixto.sh`, que ejecuta todos los escenarios con los mismos hilos y duración (10 hilos, 60 s), apaga y vuelve a encender `mysql-slave1` por su cuenta, y guarda los logs crudos y un `resumen.csv` en `resultados/fase6/`.
- **Benchmark mixto** (`oltp_read_write`) vía NGINX, y una variante "dividida" que imita a una aplicación real: 8 hilos de lectura al puerto 3308 y 2 hilos de escritura al puerto 3307, a la vez.
- **Prueba con un esclavo caído** (`mysql-slave1` detenido), apoyada en el mecanismo de health checks pasivos de la Fase 4.
- **Pruebas adicionales:** lecturas directas a cada nodo (para aislar el costo del proxy), retraso de replicación bajo carga de escritura y tiempo que tarda un esclavo en ponerse al día al volver.
- Dos corridas completas del script, para ver la variabilidad entre ejecuciones.

Por qué se hizo así:

- **La carga mixta no se puede balancear tal cual.** `oltp_read_write` usa una sola conexión por hilo hacia un solo host, y NGINX en modo stream (capa 4) no distingue un `SELECT` de un `INSERT`. Con ese script solo se puede apuntar al 3307 (todo al maestro). Por eso se añadió la prueba dividida, que sí usa los dos puertos como lo haría una aplicación real.
- **Mismas condiciones en todos los escenarios.** Misma máquina, mismos hilos, misma duración y un calentamiento previo, para que la comparación sea válida.
- **Se midió directo a cada nodo.** Sin esa línea de base no se puede saber si un resultado bajo se debe a MySQL o al proxy.

### Conceptos clave

- **Prueba dividida:** dos Sysbench simultáneos, uno `oltp_read_only` contra el 3308 y otro `oltp_write_only` contra el 3307. Se reportan por separado porque miden cosas distintas.
- **Retraso de replicación (`Seconds_Behind_Master`):** cuántos segundos va un esclavo por detrás del maestro. Bajo escritura continua deja de ser 0.
- **Consistencia eventual:** los esclavos terminan viendo los mismos datos que el maestro, pero no al instante.

---

## Entorno de las pruebas

- Equipo de **8 núcleos y 7,4 GB de RAM**, Docker sobre WSL2. Todos los contenedores (MySQL, NGINX y Sysbench) comparten esa CPU, RAM y disco, sin límites configurados.
- MySQL 8.0.46, NGINX 1.27, Sysbench 1.0.17.
- Dataset: tabla `sbtest.sbtest1` con 1.000.000 de filas, usuario `sbtest` (`mysql_native_password`).
- **Los valores absolutos no son comparables con los de la Fase 5**, que se midió en otro equipo de 12 núcleos. Solo es válida la comparación entre escenarios del mismo equipo.

---

## Comandos ejecutados, en orden

### A. Preparación del entorno (Fases 1 a 5)

La máquina de esta fase partía de cero, así que primero se levantó todo.

#### 1. Revisar el proyecto y generar el `.env`

```bash
cat > .env <<EOF
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 24)
MYSQL_REPL_USER=replicador
MYSQL_REPL_PASSWORD=$(openssl rand -hex 12)
SYSBENCH_PASSWORD=$(openssl rand -hex 12)
EOF
chmod 600 .env
```

- `openssl rand -hex N`: genera N bytes aleatorios en hexadecimal; sirve para contraseñas.
- `chmod 600`: solo el dueño puede leer y escribir el archivo. El `.env` está en `.gitignore`.

#### 2. Levantar los contenedores

```bash
docker compose up -d
```

- Falló: los esclavos salieron con `Exited (1)` (ver "Problemas comunes", problema 1).

#### 3. Crear el usuario de replicación en el maestro

```bash
docker exec mysql-master sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER IF NOT EXISTS \"$MYSQL_REPL_USER\"@\"%\" IDENTIFIED BY \"$MYSQL_REPL_PASSWORD\"; GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO \"$MYSQL_REPL_USER\"@\"%\";"'
```

- `docker exec <contenedor> sh -c '...'`: ejecuta un comando dentro de un contenedor en marcha. Las comillas simples hacen que `$MYSQL_ROOT_PASSWORD` se lea del entorno del contenedor y no de la terminal.
- `CREATE USER IF NOT EXISTS ... @"%"`: crea el usuario si no existe, accesible desde cualquier host de la red.
- `GRANT REPLICATION SLAVE, REPLICATION CLIENT`: permisos mínimos para replicar y consultar el estado.

#### 4. Recrear los esclavos con `super_read_only` desactivado solo en el primer arranque

```bash
docker compose rm -sf mysql-slave1 mysql-slave2 nginx-lb
docker volume rm proyecto-st_mysql_slave1_data proyecto-st_mysql_slave2_data
docker compose -f docker-compose.yml -f override.yml up -d mysql-slave1 mysql-slave2
```

- `compose rm -sf`: detiene y elimina los contenedores sin pedir confirmación.
- `docker volume rm`: borra los volúmenes de los esclavos, que habían quedado a medio inicializar. **Solo los de los esclavos, nunca el del maestro.**
- `f docker-compose.yml -f override.yml`: aplica un archivo adicional por encima del compose. El `override.yml` (fuera del repo) solo contenía `command: ["mysqld", "--super-read-only=OFF"]` para ambos esclavos.

#### 5. Recrear con la configuración normal y verificar

```bash
docker compose up -d
./scripts/verify-replication.sh
```

- Sin el override, los esclavos se recrean con el `my.cnf` del repo (con `super_read_only=1`). Los datos y la replicación se conservan porque viven en el volumen.
- `verify-replication.sh` debe terminar con `RESULTADO: OK` en ambos esclavos.

#### 6. Comprobar NGINX

```bash
for i in 1 2 3 4; do
  docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3308 -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT @@server_id, @@super_read_only"' 2>/dev/null
done
docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3307 -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT @@server_id"' 2>/dev/null
```

- `h nginx-lb -P 3308`: se conecta a NGINX por el puerto de lectura. Debe alternar `server_id` 2 y 3.
- Por el 3307 debe devolver `server_id` 1 (maestro).

#### 7. Crear el usuario `sbtest` y cargar el dataset

```bash
set -a; . ./.env; set +a
docker exec mysql-master sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \"CREATE DATABASE IF NOT EXISTS sbtest; CREATE USER IF NOT EXISTS 'sbtest'@'%' IDENTIFIED WITH mysql_native_password BY '$SYSBENCH_PASSWORD'; GRANT ALL ON sbtest.* TO 'sbtest'@'%';\""

docker compose run --rm -T sysbench oltp_read_only \
  --mysql-host=nginx-lb --mysql-port=3307 --mysql-user=sbtest --mysql-password=$SYSBENCH_PASSWORD \
  --mysql-db=sbtest --tables=1 --table-size=1000000 prepare
```

- `set -a; . ./.env; set +a`: carga las variables del `.env` en la shell y las exporta.
- `IDENTIFIED WITH mysql_native_password`: el cliente de Sysbench es de MariaDB y no soporta el método por defecto de MySQL 8 (`caching_sha2_password`).
- `prepare` va por el **3307** (maestro): los esclavos son `super_read_only`. La replicación copia luego los datos.
- `T`: desactiva la terminal interactiva, necesario para ejecutar sin TTY.

#### 8. Verificar el dataset en los tres nodos

```bash
./scripts/verify-replication.sh | grep -E "RESULTADO|GTID al día"
for n in mysql-master mysql-slave1 mysql-slave2; do
  docker exec $n sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT COUNT(*) FROM sbtest.sbtest1"' 2>/dev/null
done
```

- Debe dar `1000000` en cada nodo. Justo después del `prepare` el verificador dio `FALLO` por el retraso de replicación; diez segundos después dio `OK` (ver "Problemas comunes", problema 2).

### B. Paso 1 — Benchmark mixto (10 hilos, 60 s)

Se creó `scripts/benchmark-mixto.sh`. Antes de la corrida real se hizo una de humo:

```bash
chmod +x scripts/benchmark-mixto.sh
./scripts/benchmark-mixto.sh -d 5
```

- `d 5`: 5 segundos por prueba, solo para validar que el script funciona de punta a punta. Sus números no son representativos.

Corrida real, con calentamiento de 20 s:

```bash
./scripts/benchmark-mixto.sh
```

Opciones del script:

| Opción | Qué hace |
| --- | --- |
| `-t HILOS` | Hilos totales por prueba. Por defecto 10. |
| `-d SEGUNDOS` | Duración de cada prueba. Por defecto 60. |
| `-w HILOS` | De los `-t`, cuántos escriben en la prueba dividida. Por defecto 2. |

Los comandos de Sysbench que ejecuta internamente, según el escenario:

```bash
# Mixta, todo al maestro (B1)
docker compose run --rm -T sysbench oltp_read_write \
  --mysql-host=nginx-lb --mysql-port=3307 --mysql-user=sbtest --mysql-password=$SYSBENCH_PASSWORD \
  --mysql-db=sbtest --tables=1 --table-size=1000000 --threads=10 --time=60 run

# Mixta dividida (B2 y C2): dos Sysbench a la vez
docker compose run --rm -T sysbench oltp_read_only  --mysql-host=nginx-lb --mysql-port=3308 ... --threads=8 --time=60 run &
docker compose run --rm -T sysbench oltp_write_only --mysql-host=nginx-lb --mysql-port=3307 ... --threads=2 --time=60 run &
wait
```

- `oltp_read_write`: transacciones con lecturas y escrituras (UPDATE, DELETE, INSERT). `oltp_write_only`: solo la parte de escritura.
- El `&` lanza cada Sysbench en segundo plano para que corran a la vez, y `wait` espera a que ambos terminen.
- Entre escenarios, el script espera a que los esclavos tengan todos los GTID del maestro, para que el retraso de una prueba no contamine la siguiente.

### C. Paso 2 — Benchmark con un esclavo caído

Lo hace el mismo script, tras los escenarios con todo sano:

```bash
docker stop mysql-slave1
# calentamiento de 15 s para que NGINX detecte y excluya el nodo
docker compose run --rm -T sysbench oltp_read_only --mysql-host=nginx-lb --mysql-port=3308 ... --threads=10 --time=15 run
# escenarios C1 (lectura) y C2 (mixta dividida), 60 s cada uno
docker start mysql-slave1
```

- `docker stop mysql-slave1` simula la caída (Fase 4).
- El calentamiento con el nodo ya apagado deja que NGINX lo excluya antes de medir. Por eso **la latencia de detección (3 a 5 s para los primeros clientes, Fase 4) no entra en estas medias**.
- Al terminar (o con `Ctrl+C`) el script vuelve a encender `mysql-slave1` con un `trap`.

### D. Paso 3 — Pruebas adicionales

#### Retraso de replicación y puesta al día

También las hace el script: durante las pruebas divididas, un proceso en segundo plano lee `Seconds_Behind_Master` de cada esclavo cada 5 s y lo guarda en `resultados/fase6/lag.csv`. Tras reencender `slave1`, mide cuántos segundos tarda en tener todos los GTID del maestro:

```bash
SELECT GTID_SUBSET('<gtid_executed del maestro>', @@global.gtid_executed);   -- 1 = ya está al día
```

- `GTID_SUBSET(a, b)` devuelve 1 si todo el conjunto `a` está contenido en `b`. Es más fuerte que mirar solo el retraso en segundos.

#### Diagnóstico directo a cada nodo (20 s)

Se hizo porque la lectura vía NGINX (≈770 TPS) estaba muy por debajo de lo documentado en la Fase 5 (≈5.100 TPS):

```bash
for h in mysql-slave1 mysql-slave2 mysql-master; do
  docker compose run --rm -T sysbench oltp_read_only --mysql-host=$h --mysql-port=3306 \
    --mysql-user=sbtest --mysql-password=$SYSBENCH_PASSWORD --mysql-db=sbtest \
    --tables=1 --table-size=1000000 --threads=10 --time=20 run
done
docker stats --no-stream --format '{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}}'
uptime
```

- `-mysql-port=3306` y el nombre del nodo: se salta NGINX y va directo al contenedor.
- `docker stats --no-stream`: foto del uso de CPU y memoria de cada contenedor.
- `uptime`: la carga media del equipo (aparecía en ≈10 con solo 8 núcleos).
- Resultado: los tres nodos rindieron igual (≈2.070 TPS), por lo que el cuello de botella está en el salto por NGINX. Esa medición se incorporó al script como escenario A3.

#### Verificación final

```bash
./scripts/verify-replication.sh | grep -E "RESULTADO|GTID al día"
for n in mysql-master mysql-slave1 mysql-slave2; do
  docker exec $n sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT COUNT(*) FROM sbtest.sbtest1"' 2>/dev/null
done
```

- Tras todas las escrituras, el dataset sigue con 1.000.000 de filas en los tres nodos y la replicación en `OK`. Las pruebas de escritura modifican filas pero no cambian su número.

---

## Tabla comparativa final de métricas

### Esta fase (10 hilos, 60 s, equipo de 8 núcleos, 0 errores en todas las pruebas)

Valores de la corrida 2 (la corrida 1 difiere como máximo un 12 %).

| Esc. | Escenario | Hilos | TPS | QPS | avg (ms) | p95 (ms) | max (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A1 | Lectura vía NGINX :3308 (2 esclavos) | 10 | 768 | 12.295 | 13,00 | 18,61 | 50,69 |
| A2 | Lectura directo al maestro (sin proxy) | 10 | 2.025 | 32.405 | 4,93 | 10,09 | 62,30 |
| A3 | Lectura directo a 1 esclavo (sin proxy) | 10 | 2.139 | 34.231 | 4,67 | 8,58 | 58,48 |
| B1 | Mixta `oltp_read_write` vía :3307 (todo al maestro) | 10 | 140 | 2.807 | 71,16 | 106,75 | 251,73 |
| B2 | Mixta dividida: lecturas vía :3308 | 8 | 557 | 8.913 | 14,35 | 26,20 | 187,36 |
| B2 | Mixta dividida: escrituras vía :3307 | 2 | 32 | 194 | 61,94 | 118,92 | 428,78 |
| C1 | Lectura vía NGINX con **slave1 caído** | 10 | 776 | 12.424 | 12,87 | 18,28 | 59,31 |
| C2 | Dividida con slave1 caído: lecturas | 8 | 560 | 8.958 | 14,28 | 27,66 | 114,42 |
| C2 | Dividida con slave1 caído: escrituras | 2 | 43 | 259 | 46,40 | 66,84 | 202,89 |

Corrida 1, para ver la variabilidad (TPS): A1 806 · A2 2.166 · B1 125 · B2 lecturas 551 / escrituras 36 · C1 775 · C2 lecturas 542 / escrituras 41.

### Extras medidos en la misma corrida

| Medición | Resultado |
| --- | --- |
| Retraso de replicación bajo escrituras (máx. `Seconds_Behind_Master`) | B2: 11 s (slave1) y 6 s (slave2). C2: 8 s y 3 s |
| Puesta al día de slave1 al volver (GTID) | 7 s, tras ≈60 s de escrituras con slave1 caído |
| Lectura directa a slave1 / slave2 / maestro (20 s, diagnóstico) | 2.076 / 2.099 / 2.044 TPS |

### Fase 5 (solo lectura, equipo de 12 núcleos; otra máquina)

| Hilos | Vía NGINX (2 esclavos) | Vía NGINX (1 esclavo) | Directo a 1 esclavo |
| --- | --- | --- | --- |
| 10 (60 s) | 5174 TPS · avg 1,93 ms · p95 2,52 ms | 4927 TPS · avg 2,03 ms · p95 2,76 ms | 8014 TPS · avg 1,25 ms · p95 1,82 ms |
| 64 (30 s) | 5136 TPS · avg 12,45 ms · p95 23,10 ms | 5358 TPS · avg 11,94 ms · p95 23,52 ms | 7791 TPS · avg 8,21 ms · p95 17,63 ms |
| 128 (30 s) | 4873 TPS · avg 26,25 ms · p95 48,34 ms | 4977 TPS · avg 25,70 ms · p95 53,85 ms | 7321 TPS · avg 17,47 ms · p95 39,65 ms |

### Costo del proxy: la proporción sí es comparable

|  | Fase 5 (12 núcleos) | Fase 6 (8 núcleos) |
| --- | --- | --- |
| Directo a 1 esclavo | 8.014 TPS | 2.139 TPS |
| Vía NGINX (2 esclavos) | 5.174 TPS | 768 TPS |
| Pérdida por pasar por NGINX | −35 % | −64 % |

---

## Conclusiones preliminares

1. **El balanceo no mejoró el throughput en este entorno.** Vía NGINX se obtuvo ≈770 TPS frente a ≈2.100 directo a un nodo. Los tres nodos rinden igual por separado, así que el cuello de botella no es MySQL sino el salto por el proxy. El costo fue de −35 % en la Fase 5 y de −64 % en esta fase, porque en un equipo con menos núcleos el proxy compite más por la misma CPU.
2. **Dos esclavos rinden igual que uno.** A1 (2 esclavos, 768 TPS) y C1 (1 esclavo vivo, 776 TPS) son equivalentes. Todos los contenedores comparten CPU, RAM y disco, así que un segundo esclavo reparte la capacidad existente en vez de añadir más. El balanceo de lectura aporta cuando cada esclavo corre en hardware distinto y un solo nodo es el cuello de botella.
3. **Con un esclavo caído el rendimiento casi no cambió** (C1 ≈ A1, +1 %; las lecturas de C2 ≈ B2). Lo que el balanceador sí garantiza es la **disponibilidad**: 0 errores en todas las pruebas, incluida la que tuvo `slave1` apagado. El costo real de una caída está en la latencia de detección (3 a 5 s para los primeros clientes, Fase 4), que estas medias no incluyen porque se hizo un calentamiento con el nodo ya apagado.
4. **Las escrituras mejoraron con un esclavo menos** (32 → 43 TPS en la prueba dividida). La hipótesis es que hay menos replicación compitiendo por la CPU; no se aisló con una prueba adicional.
5. **Las escrituras son lo más caro y no escalan con el balanceo.** La mixta completa (B1) llegó a 140 TPS con ≈71 ms de latencia media. Todas pasan por el único maestro, que además persiste el binlog en cada commit.
6. **Consistencia eventual visible.** Bajo escritura continua los esclavos fueron entre 3 y 11 s por detrás del maestro (máximo 11 s con solo 2 hilos de escritura). Una aplicación que lea justo después de escribir por el 3308 puede no ver su propio cambio.
7. **La recuperación funciona sola.** Al volver, `slave1` se puso al día por GTID en 7 s, sin intervención manual.

### Limitaciones

- Una sola máquina y dos corridas por escenario; las diferencias menores a ≈12 % están dentro del ruido.
- Cliente (Sysbench), proxy y servidores comparten el mismo host, y la carga media del equipo superó los 8 núcleos durante las pruebas.
- Un solo dataset de 1 tabla y 1.000.000 de filas.
- No se probó la caída del maestro ni un esclavo con la replicación rota (el health check de NGINX es solo TCP y lo seguiría considerando sano).
- La causa exacta del costo tan alto del proxy en este equipo no se aisló: se midió el efecto, no se probó el mecanismo.

---

## Problemas comunes y solución

### 1. Los esclavos salen con `Exited (1)` en el primer arranque: `ERROR 1290 ... --super-read-only`

- **Síntoma:** `docker compose up -d` terminó con `dependency failed to start: container mysql-slave1 exited (1)`. El log de `mysql-slave1` terminaba en `ERROR 1290 (HY000) at line 1: The MySQL server is running with the --super-read-only option so it cannot execute this statement`.
- **Causa:** el `my.cnf` de los esclavos trae `super_read_only=1`. En un volumen vacío, la imagen de MySQL arranca un servidor temporal para fijar la contraseña de `root`, y con esa opción activa no puede escribir. En el proyecto original la opción se añadió después de que los esclavos ya existían, por eso nunca había fallado.
- **Solución:** borrar los volúmenes de los esclavos (que quedaron a medio inicializar), levantarlos una vez con `-super-read-only=OFF` mediante un `override.yml` fuera del repo, y recrearlos después con la configuración normal (pasos 4 y 5 de los comandos). No se modificó ningún archivo del repositorio.
- **Mejora pendiente para el equipo:** automatizar el primer arranque para que `docker compose up -d` funcione de una sola vez.

### 2. Ningún archivo del repo crea el usuario `replicador`

- **Síntoma:** en una máquina nueva, los esclavos no pueden replicar.
- **Causa:** el usuario se creó a mano en la Fase 1 y el README solo dice `docker compose up -d`.
- **Solución:** crearlo en el maestro con `CREATE USER` / `GRANT` (paso 3). Es el mismo problema que describe la Fase 4; se recomienda un script de inicialización del maestro (`mysql/master-init/`).

### 3. `verify-replication.sh` da `FALLO` justo después del `prepare`

- **Síntoma:** tras cargar 1.000.000 de filas, ambos esclavos mostraban `GTID al día con maestro: no`, aunque `COUNT(*)` ya daba 1000000 en los tres nodos.
- **Causa:** el `COUNT(*)` ya coincidía, pero la creación del índice secundario de `sbtest1` todavía se estaba replicando.
- **Solución:** esperar unos segundos y volver a verificar: diez segundos después daba `OK`, con retraso 0. No era un error. Por eso `benchmark-mixto.sh` espera a que los GTID coincidan entre escenarios.

### 4. Rendimiento de lectura muy inferior al de la Fase 5

- **Síntoma:** la lectura vía NGINX daba ≈770–800 TPS, contra ≈5.100 documentados en la Fase 5.
- **Causa:** no era un fallo. Es otro equipo (8 núcleos frente a 12) y el costo del proxy resultó mucho mayor (−64 % frente a −35 %). Se confirmó midiendo directo a cada nodo: los tres daban ≈2.070 TPS, así que MySQL no era el límite.
- **Solución:** no comparar valores absolutos entre equipos, solo la proporción entre escenarios del mismo equipo. Se añadió la medición directa a un esclavo (A3) al script para que esa línea base quede siempre en la tabla.

### 5. `oltp_read_write` no se puede repartir entre maestro y esclavos

- **Síntoma:** al querer medir "lectura/escritura mixta con balanceo", todo el tráfico del script iba al maestro.
- **Causa:** Sysbench usa una única conexión por hilo hacia un solo host, y NGINX trabaja en capa 4: no distingue `SELECT` de `INSERT`. Apuntar `oltp_read_write` al 3308 fallaría por `super_read_only`.
- **Solución:** medir dos configuraciones: la mixta contra el 3307 (B1) y la prueba dividida con dos Sysbench simultáneos, uno de lectura al 3308 y uno de escritura al 3307 (B2). Esta última representa mejor a una aplicación real.

### 6. La corrida de 5 s daba números muy bajos

- **Síntoma:** en la corrida de humo, la lectura vía NGINX daba ≈720 TPS y los máximos de latencia eran irregulares.
- **Causa:** con 5 s la prueba apenas sale del arranque (buffer pool frío, conexiones nuevas).
- **Solución:** usarla solo para validar el script. Las corridas reales usan 60 s, con un calentamiento de 20 s previo que no se reporta.

### 7. Detalles que no son errores

- Las notificaciones de "tarea completada" del lanzador en segundo plano aparecieron antes de que terminara el benchmark: avisaban de que el comando de lanzamiento había terminado, no de la prueba. Se esperó al marcador `done` del archivo de salida.
- El mensaje `Using a password on the command line interface can be insecure` de `mysql` es solo un aviso; se descarta con `2>/dev/null`.
- Los escenarios con `slave1` caído muestran `slave1=caído` en `lag.csv`; es esperado, no una falla del muestreador.

---

## Reglas de seguridad del proyecto

- Nunca usar `docker compose down -v`: borra también el volumen del maestro.
- Trabajar desde el sistema de archivos de Linux/WSL (`~/Proyecto-ST`), no desde `/mnt/c`.
- Para escribir, usar siempre el puerto 3307; el 3308 es de solo lectura.
- Antes de repetir las pruebas, comprobar que `verify-replication.sh` da `OK` y que las tres tablas tienen 1.000.000 de filas.

---

## Checklist de finalización

- [x]  Benchmark ejecutado: 10 hilos, 60 segundos, lectura/escritura mixta
- [x]  TPS y latencia del benchmark mixto registrados
- [x]  Prueba adicional ejecutada con un esclavo caído, midiendo el impacto en el rendimiento
- [x]  Pruebas adicionales: retraso de replicación, puesta al día de slave1 y diagnóstico directo a cada nodo
- [x]  Todas las métricas (Fase 5 y Fase 6) consolidadas en una tabla comparativa
- [x]  Conclusiones preliminares redactadas sobre qué configuración rindió mejor y por qué
- [x]  README actualizado con los resultados finales y cómo reproducir todas las pruebas