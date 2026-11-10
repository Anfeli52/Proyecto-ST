# 2.2. Fase 2 — Replicación de Esclavos + Verificación (Eddie)

## Resumen

### Qué se construyó

Se agregaron dos nodos esclavos (`mysql-slave1` y `mysql-slave2`) al maestro creado en la Fase 1. Todo corre en contenedores Docker orquestados con Docker Compose, sin nada instalado en el host. Cada esclavo se configura solo la primera vez que arranca gracias a un script en `/docker-entrypoint-initdb.d/`, y se creó un script reutilizable (`scripts/verify-replication.sh`) que comprueba el estado de la replicación con un solo comando.

### Por qué se hizo así

- **Replicación por GTID.** Cada transacción del maestro recibe una etiqueta única. El esclavo solo pide "lo que no tengo" (`MASTER_AUTO_POSITION=1`), sin tener que indicar archivo ni posición del binlog.
- **Un server-id distinto por nodo.** MySQL usa ese número para identificar cada servidor dentro de la replicación. El maestro usa 1, `mysql-slave1` usa 2 y `mysql-slave2` usa 3.
- **Un volumen por nodo.** Cada contenedor tiene su propio disco, así los datos de un esclavo nunca pisan los del maestro.
- **read_only=1 en los esclavos.** Los datos solo deben entrar por replicación y no por escrituras directas.
- **Este bloque alimenta la siguiente fase.** Los dos esclavos quedan disponibles en la red `mysql_net` (puerto 3306) para que NGINX en modo stream reparta las lecturas entre ellos.

### Concepto clave, el binlog

El binlog (binary log) es el cuaderno donde el maestro anota cada cambio que hace en los datos (INSERT, UPDATE, DELETE, CREATE...). Los esclavos se conectan al maestro con el usuario de replicación, descargan esas anotaciones a su propio cuaderno intermedio (el relay log) y las repiten en su base local. Por eso el usuario de replicación tiene los privilegios REPLICATION SLAVE (pedir el binlog) y REPLICATION CLIENT (consultar el estado del maestro).

### Estado final

| Elemento | Resultado |
| --- | --- |
| Esclavos levantados | `mysql-slave1` (server-id 2) y `mysql-slave2` (server-id 3) en estado healthy |
| Slave_IO_Running / Slave_SQL_Running | Yes en ambos |
| Seconds_Behind_Master | 0 en ambos |
| GTID de los esclavos vs maestro | Todo el conjunto del maestro está contenido en cada esclavo |
| Prueba de datos | Filas escritas en el maestro aparecieron idénticas en los dos esclavos |

---

## Configuración final de la fase

### Estructura de archivos nuevos

```
mysql/
  slave1/my.cnf
  slave2/my.cnf
  slave-init/01-replication.sh
scripts/
  verify-replication.sh
```

### mysql/slave1/my.cnf (en slave2 solo cambia server-id=3)

```
[mysqld]
server-id=2
read_only=1
relay-log=relay-bin
gtid_mode=ON
enforce_gtid_consistency=ON
```

### mysql/slave-init/01-replication.sh

```bash
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
EOF
```

### Servicio de esclavo en docker-compose.yml (el de slave2 cambia nombres y números)

```yaml
  mysql-slave1:
    image: mysql:8.0
    container_name: mysql-slave1
    depends_on:
      mysql-master:
        condition: service_healthy
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_REPL_USER: ${MYSQL_REPL_USER}
      MYSQL_REPL_PASSWORD: ${MYSQL_REPL_PASSWORD}
    volumes:
      - mysql_slave1_data:/var/lib/mysql
      - ./mysql/slave1/my.cnf:/etc/mysql/conf.d/my.cnf:ro
      - ./mysql/slave-init:/docker-entrypoint-initdb.d:ro
    networks:
      - mysql_net
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p\"$$MYSQL_ROOT_PASSWORD\" --silent"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 180s
```

Y al final del archivo, en la sección raíz:

```yaml
volumes:
  mysql_master_data:
  mysql_slave1_data:
  mysql_slave2_data:
```

---

## Comandos ejecutados en la sesión, en orden

### Paso 1 - Levantar los contenedores esclavos

**1.1 Crear las carpetas de configuración**

```bash
mkdir -p mysql/slave1 mysql/slave2
```

- `mkdir` crea carpetas.
- `p` evita error si ya existen y crea las carpetas intermedias que falten.

Después se crearon los `my.cnf` de cada esclavo (ver sección de configuración final).

**1.2 Validar el compose y levantar**

```bash
docker compose config --quiet
docker compose up -d
docker compose ps
```

- `config --quiet` valida el YAML y resuelve las variables del `.env`. No imprime nada si todo está bien.
- `up -d` crea y arranca los contenedores faltantes en segundo plano (`d` es detached). El maestro no se toca.
- `ps` lista los contenedores que están corriendo y su estado de salud.

### Paso 2 - Scripts de inicialización

**2.1 Revisar el maestro antes de escribir el script**

```bash
docker exec mysql-master sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW VARIABLES LIKE \"server_id\"; SHOW VARIABLES LIKE \"log_bin\"; SHOW VARIABLES LIKE \"gtid_mode\"; SHOW MASTER STATUS; SHOW DATABASES;"'
```

- `docker exec <contenedor> <comando>` ejecuta un comando dentro de un contenedor que ya está corriendo.
- `sh -c '...'` con comillas simples hace que `$MYSQL_ROOT_PASSWORD` se lea del entorno del contenedor y no de la terminal del host.
- `uroot -p"..."` define usuario y contraseña del cliente `mysql`.
- `e "..."` ejecuta las sentencias SQL y sale.
- `SHOW MASTER STATUS` muestra el binlog actual del maestro y los GTID ejecutados.

Resultado obtenido: `server_id = 1`, `log_bin = ON`, `gtid_mode = ON` y solo las bases del sistema. Eso permitió usar GTID con auto-posición y evitar un volcado previo.

**2.2 Crear el script de replicación**

```bash
mkdir -p mysql/slave-init
chmod +x mysql/slave-init/01-replication.sh
```

- `chmod +x` le da permiso de ejecución al script.

El contenido del script está en la sección de configuración final. Parámetros importantes de `CHANGE MASTER TO`:

| Parámetro | Para qué sirve |
| --- | --- |
| `MASTER_HOST` | Nombre del maestro. Docker lo resuelve por la red `mysql_net` |
| `MASTER_USER` / `MASTER_PASSWORD` | Usuario de replicación, tomado de las variables del contenedor para no escribir contraseñas en el repo |
| `MASTER_AUTO_POSITION=1` | Activa la replicación por GTID |
| `GET_MASTER_PUBLIC_KEY=1` | Permite pedir la clave pública RSA del maestro. Necesario porque MySQL 8 usa `caching_sha2_password`, que exige conexión cifrada o intercambio RSA |

`START SLAVE` enciende los dos hilos de replicación, el IO (descarga el binlog) y el SQL (aplica los cambios).

### Paso 3 - Arrancar y verificar la replicación

**3.1 Levantar y revisar el estado**

```bash
docker compose up -d
docker compose ps
docker compose ps -a
```

- `ps -a` incluye también los contenedores detenidos (Exited), que `ps` esconde.

**3.2 Confirmar que el script se ejecutó**

```bash
docker logs mysql-slave1 2>&1 | grep -i "01-replication"
docker exec mysql-slave1 ls -l /docker-entrypoint-initdb.d
docker logs mysql-slave1 2>&1 | grep -i -E "entrypoint|initdb|ready for connections"
docker logs mysql-slave1 2>&1 | tail -40
```

- `docker logs` muestra lo que el contenedor imprimió al arrancar.
- `2>&1` junta los mensajes de error con la salida normal para que `grep` o `tail` vean todo.
- `grep -i` filtra líneas ignorando mayúsculas. `E` permite varias palabras a la vez con `a|b|c`.
- `tail -40` muestra solo las últimas 40 líneas, donde casi siempre está el motivo de un fallo.
- `ls -l` dentro del contenedor confirma que la carpeta se montó y que el script tiene permisos de ejecución.

**3.3 Leer el estado de la replicación**

```bash
for s in mysql-slave1 mysql-slave2; do echo "== $s =="; docker exec $s sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW SLAVE STATUS\G"' 2>/dev/null | grep -E "Master_Host|Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Auto_Position|Retrieved_Gtid_Set|Executed_Gtid_Set|Last_IO_Error|Last_SQL_Error"; done
```

- `for s in a b; do ... done` repite el bloque una vez por cada nombre.
- `SHOW SLAVE STATUS\G` pregunta al esclavo cómo va su trabajo. `\G` imprime un campo por línea.
- `2>/dev/null` descarta el aviso de contraseña en la línea de comandos.

**3.4 Comparar los GTID de los tres servidores**

```bash
for s in mysql-master mysql-slave1 mysql-slave2; do echo "== $s =="; docker exec $s sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT @@global.gtid_executed\G"' 2>/dev/null; done
```

- `@@global.gtid_executed` es el conjunto completo de transacciones que cada servidor ya ejecutó.

### Paso 4 - Script reutilizable de verificación

```bash
mkdir -p scripts
chmod +x scripts/verify-replication.sh
./scripts/verify-replication.sh
echo "Código de salida: $?"
```

El script `scripts/verify-replication.sh` revisa cada esclavo (por defecto `mysql-slave1` y `mysql-slave2`, o los que se pasen como argumentos) y comprueba seis condiciones.

| Condición | Cuándo se considera correcta |
| --- | --- |
| Slave_IO_Running | Yes |
| Slave_SQL_Running | Yes |
| Seconds_Behind_Master | 0 |
| Last_IO_Error | Vacío |
| Last_SQL_Error | Vacío |
| GTID al día | `GTID_SUBSET(gtid_del_maestro, gtid_del_esclavo)` devuelve 1 |
- `GTID_SUBSET(a, b)` devuelve 1 si todo el conjunto `a` está contenido en `b`. Es más fuerte que mirar solo el retraso en segundos, porque compara contenido.
- El script termina con código 0 si todo está bien y con 1 si algo falla, así se puede usar desde otros scripts o pipelines.

### Paso 5 - Prueba de sincronización de datos

**5.1 Escribir solo en el maestro**

```bash
docker exec mysql-master sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS prueba_replicacion; CREATE TABLE IF NOT EXISTS prueba_replicacion.mensajes (id INT AUTO_INCREMENT PRIMARY KEY, texto VARCHAR(100), creado TIMESTAMP DEFAULT CURRENT_TIMESTAMP); INSERT INTO prueba_replicacion.mensajes (texto) VALUES (\"hola desde el maestro\"), (\"segundo registro\");"' 2>/dev/null
```

- Cada sentencia que cambia datos queda anotada en el binlog del maestro con su GTID. El GTID del maestro avanzó de `1-10` a `1-13` (tres transacciones nuevas).
- `IF NOT EXISTS` evita error si se repite el comando.

**5.2 Leer en los dos esclavos**

```bash
for s in mysql-slave1 mysql-slave2; do echo "== $s =="; docker exec $s sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT * FROM prueba_replicacion.mensajes;"' 2>/dev/null; done
```

Ambos esclavos mostraron las mismas dos filas, incluso con la misma marca de tiempo en `creado`. Eso demuestra que el valor lo calculó el maestro y viajó dentro del binlog, y los esclavos no volvieron a calcularlo.

**5.3 Verificar de nuevo**

```bash
./scripts/verify-replication.sh
```

El GTID del maestro quedó en `1-13` y los dos esclavos siguieron en `OK`.

**5.4 Limpiar la prueba**

```bash
docker exec mysql-master sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE prueba_replicacion;"' 2>/dev/null
for s in mysql-master mysql-slave1 mysql-slave2; do echo "== $s =="; docker exec $s sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES;"' 2>/dev/null; done
./scripts/verify-replication.sh
```

- `DROP DATABASE` elimina la base completa. También se replica, y los esclavos la borraron solos.
- Al final ninguno de los tres servidores lista `prueba_replicacion` y el script de verificación sigue en `OK`.

---

## Campos clave de SHOW SLAVE STATUS

Valores obtenidos en las pruebas finales, iguales en `mysql-slave1` y `mysql-slave2`.

| Campo | Qué significa | Valor en las pruebas |
| --- | --- | --- |
| `Master_Host` | Servidor al que se conecta el esclavo | `mysql-master` |
| `Slave_IO_Running` | Hilo que se conecta al maestro y descarga su binlog al relay log. Si dice No o Connecting, el problema está en la conexión (host, usuario, contraseña o autenticación) | Yes |
| `Slave_SQL_Running` | Hilo que aplica en la base local los cambios descargados. Si dice No, la descarga funcionó pero falló al aplicar algo | Yes |
| `Seconds_Behind_Master` | Retraso aproximado respecto al maestro. NULL suele indicar que alguno de los dos hilos está detenido | 0 |
| `Slave_SQL_Running_State` | Estado textual del hilo SQL | "Replica has read all relay log; waiting for more updates" (reposo ideal, ya procesó todo) |
| `Auto_Position` | 1 significa que la replicación usa GTID | 1 |
| `Retrieved_Gtid_Set` | Transacciones que el hilo IO ya descargó del maestro | `60490b91-...:1-10` en ese momento |
| `Executed_Gtid_Set` | Transacciones que el esclavo ya aplicó. Incluye las del maestro y las 5 locales que la imagen de MySQL ejecuta al inicializar cada nodo | Contenía `60490b91-...:1-10` más su propio UUID `:1-5` |
| `Last_IO_Error` | Motivo del último fallo del hilo IO | Vacío |
| `Last_SQL_Error` | Motivo del último fallo del hilo SQL | Vacío |

Regla práctica ante cualquier fallo: leer primero `Last_IO_Error` y `Last_SQL_Error`, porque dicen cuál de los dos hilos falló y por qué, antes de intentar arreglar nada.

---

## Notas para las siguientes fases

- Los esclavos usan `read_only=1`, pero `root` tiene privilegio SUPER y puede escribir igualmente. La aplicación que lea a través de NGINX debería usar un usuario sin permisos de escritura. Opcionalmente se puede activar `super_read_only=1` para bloquear también a `root`.
- Los scripts de `mysql/slave-init/` solo corren con el volumen vacío. Para reconfigurar un esclavo desde cero, eliminar su contenedor y su volumen y levantarlo otra vez.
- Nunca usar `docker compose down -v`, porque borra también el volumen del maestro y se pierde la Fase 1.
- Nodos de lectura disponibles para NGINX stream: `mysql-slave1:3306` y `mysql-slave2:3306`, ambos en la red `mysql_net`.