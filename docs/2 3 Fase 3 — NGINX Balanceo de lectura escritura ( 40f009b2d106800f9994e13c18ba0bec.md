# 2.3. Fase 3 — NGINX: Balanceo de lectura/escritura (Christian)

# Fase 3: NGINX stream, balanceo de lectura/escritura

**Responsable:** Christian David Home Acero
**Proyecto:** Balanceo de carga de lectura MySQL (replicación maestro-esclavo + NGINX stream, todo en Docker Compose)
**Ruta de trabajo:** `~/proyecto-mysql-lb` (realizado en WSL, no `/mnt/c`)

---

# Resumen

## Qué se configuró

Se añadió un contenedor `nginx-lb` (imagen `nginx:1.27`) que funciona como balanceador TCP con el módulo `stream`. Expone dos puertos al host y es el único servicio que publica puertos:

| Puerto (host) | Destino | Uso |
| --- | --- | --- |
| `3307` | `mysql-master:3306` | Escrituras: siempre al maestro |
| `3308` | `mysql-slave1:3306` y `mysql-slave2:3306` | Lecturas: repartidas con `least_conn` |

Los tres nodos MySQL siguen sin puertos publicados (solo `3306/tcp` interno en la red `mysql_net`).

## Por qué se hizo así

- **MySQL no habla HTTP.** Usa un protocolo binario sobre TCP, por eso se usa el módulo `stream` (capa 4) y no `http` (capa 7).
- **Dos puertos separados.** NGINX en capa 4 no ve el SQL, así que no puede distinguir un `SELECT` de un `INSERT`. La aplicación elige el puerto: 3307 para escribir, 3308 para leer.
- **`least_conn` en lugar de round robin.** Las conexiones MySQL duran tiempos muy distintos (un pool largo frente a un script rápido). `least_conn` manda cada conexión nueva al esclavo con menos conexiones activas.
- **`zone` en el upstream.** Sin memoria compartida entre workers, `least_conn` no funciona correctamente (ver "Problemas comunes").
- **`super_read_only=1` en los esclavos.** Impide que incluso `root` escriba en un esclavo por el puerto de lectura.

## Stream vs HTTP

|  | `http` (capa 7) | `stream` (capa 4) |
| --- | --- | --- |
| Entiende | URLs, cabeceras, cookies | Solo IP y puerto |
| Decide por | Contenido de la petición | La conexión entera |
| Unidad de balanceo | Cada petición HTTP | **Cada conexión TCP** |
| Directiva de reenvío | `proxy_pass http://...` | `proxy_pass nombre_upstream;` |

Consecuencia clave: el reparto es **por conexión, no por consulta**. Una conexión que ejecuta 100 `SELECT` los hará todos contra el mismo esclavo.

---

# Comandos y configuración, en orden

## Paso 1. Crear la carpeta de NGINX

```bash
cd ~/proyecto-mysql-lb
mkdir -p nginx
```

- `mkdir -p` crea la carpeta y no da error si ya existe.

## Paso 2. Escribir `nginx/nginx.conf` (versión final)

```
worker_processes auto;
error_log /dev/stderr warn;

events {
    worker_connections 1024;
}

stream {
    log_format mysql '$remote_addr -> :$server_port -> $upstream_addr '
                     'estado=$status duracion=$session_time s';
    access_log /dev/stdout mysql;

    # ---------- ESCRITURA: siempre al maestro ----------
    upstream mysql_write {
        server mysql-master:3306;
    }

    server {
        listen 3307;
        proxy_pass mysql_write;
        proxy_connect_timeout 5s;
    }

    # ---------- LECTURA: balanceada entre esclavos ----------
    upstream mysql_read {
        zone mysql_read 64k;
        least_conn;
        server mysql-slave1:3306 max_fails=2 fail_timeout=10s;
        server mysql-slave2:3306 max_fails=2 fail_timeout=10s;
    }

    server {
        listen 3308;
        proxy_pass mysql_read;
        proxy_connect_timeout 5s;
    }
}
```

Qué hace cada directiva:

| Directiva | Qué hace |
| --- | --- |
| `worker_processes auto` | Un proceso worker por CPU disponible |
| `events {}` | Bloque obligatorio en un `nginx.conf` completo |
| `stream {}` | Reemplaza a `http {}`: todo lo de dentro trabaja en TCP |
| `log_format` / `access_log` | Registra, al cerrar cada conexión, el origen, el puerto, el nodo destino (`$upstream_addr`), el estado y la duración |
| `upstream nombre {}` | Grupo de servidores destino |
| `zone nombre tamaño` | Memoria compartida entre workers: contadores y fallos globales |
| `least_conn` | Algoritmo: la conexión nueva va al servidor con menos conexiones activas |
| `server ... max_fails=2 fail_timeout=10s` | Si un servidor falla 2 veces en 10 s, se retira del reparto 10 s |
| `server { listen PUERTO; }` | Puerto donde NGINX acepta conexiones |
| `proxy_pass nombre;` | Reenvía la conexión al upstream (sin `http://`) |
| `proxy_connect_timeout` | Tiempo máximo para conectar con el destino |

## Paso 3. Añadir el servicio a `docker-compose.yml`

Dentro de `services:`:

```yaml
  nginx-lb:
    image: nginx:1.27
    container_name: nginx-lb
    depends_on:
      mysql-master:
        condition: service_healthy
      mysql-slave1:
        condition: service_healthy
      mysql-slave2:
        condition: service_healthy
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    ports:
      - "3307:3307"   # escritura -> maestro
      - "3308:3308"   # lectura -> esclavos
    networks:
      - mysql_net
```

- `depends_on` con `service_healthy`: NGINX resuelve los nombres al arrancar, así que los tres MySQL deben existir antes.
- Solo este servicio tiene `ports:`. Los nodos MySQL quedan en la red interna.

## Paso 4. Validar la sintaxis dentro de la red del proyecto

```bash
docker network ls | grep mysql_net
docker run --rm --network proyecto-mysql-lb_mysql_net \
  -v "$PWD/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
  nginx:1.27 nginx -t
```

- La primera línea averigua el nombre real de la red (Compose le añade el prefijo del proyecto).
- `nginx -t` valida la configuración. Debe terminar con `test is successful`.
- Hay que ejecutarlo **dentro de la red** para que los nombres `mysql-master`, `mysql-slave1`... se resuelvan.

## Paso 5. Levantar NGINX y verificar

```bash
docker compose up -d nginx-lb
docker compose ps
docker logs nginx-lb 2>&1 | tail -20
docker exec nginx-lb nginx -V 2>&1 | grep -o "with-stream"
docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

- `with-stream` confirma que la imagen oficial incluye el módulo (aparece varias veces porque `grep -o` imprime cada coincidencia: `-with-stream`, `-with-stream_ssl_module`...).
- La última línea debe mostrar puertos publicados **solo** en `nginx-lb` (`3307-3308`). Los tres MySQL muestran solo `3306/tcp, 33060/tcp`.

## Paso 6. Prueba A: reparto de lecturas con conexiones rápidas (3308)

```bash
for i in 1 2 3 4 5 6; do
  docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3308 -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT @@hostname, @@server_id"' 2>/dev/null
done
```

- Cada iteración es una conexión nueva.
- `@@hostname` devuelve el ID del contenedor, por eso se consulta también `@@server_id` (maestro = 1, slave1 = 2, slave2 = 3).
- Resultado esperado (tras la corrección con `zone`): `3, 2, 3, 2, 3, 2`.

## Paso 7. Prueba B: `least_conn` con conexiones simultáneas

```bash
sleep 35
for i in 1 2; do
  docker exec -d mysql-master sh -c 'mysql -h nginx-lb -P 3308 -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT @@server_id, SLEEP(30)"'
done
sleep 2
docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3308 -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT @@server_id"' 2>/dev/null
sleep 32
docker logs nginx-lb 2>&1 | tail -6
```

- `exec -d` lanza las conexiones largas en segundo plano. `SLEEP(30)` las mantiene abiertas 30 s.
- El log de stream se escribe **al cerrar** la conexión, por eso el `sleep 32` antes de leerlo.
- Resultado obtenido: las dos conexiones largas (`duracion≈30 s`) fueron a IPs distintas (`172.18.0.3` y `172.18.0.4`), un esclavo cada una.

## Paso 8. Prueba C: las escrituras solo llegan al maestro (3307)

```bash
docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3307 -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT @@server_id AS nodo; CREATE DATABASE prueba_nginx; CREATE TABLE prueba_nginx.t (id INT AUTO_INCREMENT PRIMARY KEY, nodo INT); INSERT INTO prueba_nginx.t (nodo) VALUES (@@server_id);"' 2>/dev/null

for i in 1 2 3 4; do
  docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3308 -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT @@server_id, nodo FROM prueba_nginx.t"' 2>/dev/null
done
./scripts/verify-replication.sh

docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3307 -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE prueba_nginx;"' 2>/dev/null
```

- Resultado obtenido: `nodo = 1` (escribió el maestro) y la fila se leyó desde los esclavos 2 y 3 con `nodo = 1`, es decir, llegó por replicación.
- El verificador dio `OK` en ambos esclavos.
- El `DROP DATABASE` final se hace por el 3307 y se replica a los esclavos.

## Paso 9. Corrección: añadir `zone` al upstream de lectura

Las pruebas A y B inicialmente mandaban todo a un solo esclavo. Se corrigió añadiendo `zone mysql_read 64k;` al upstream (ya incluido en el `nginx.conf` del Paso 2) y recargando:

```bash
docker run --rm --network proyecto-mysql-lb_mysql_net \
  -v "$PWD/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
  nginx:1.27 nginx -t
docker exec nginx-lb nginx -s reload
```

- `nginx -s reload` recarga la configuración sin parar el contenedor.

## Paso 10. Prueba de tolerancia a fallos

```bash
docker stop mysql-slave1
for i in 1 2 3 4; do
  docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3308 -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT @@server_id"' 2>/dev/null
done
docker start mysql-slave1
```

- Con slave1 parado: `3, 3, 3, 3`. Ninguna conexión falló, NGINX reintentó con slave2.
- Tras `docker start`, el reparto volvió a alternar (`3, 2, 3, 2`) sin recargar NGINX.

```bash
./scripts/verify-replication.sh
```

- Confirmó que slave1 se puso al día por GTID: ambos esclavos en `OK`, GTID del maestro en `1-12`.

## Paso 11. Blindar los esclavos con `super_read_only=1`

En `mysql/slave1/my.cnf` y `mysql/slave2/my.cnf`, justo debajo de `read_only=1`:

```
[mysqld]
server-id=2          # 3 en slave2
read_only=1
super_read_only=1
relay-log=relay-bin
gtid_mode=ON
enforce_gtid_consistency=ON
```

O con `sed`:

```bash
sed -i 's/^read_only=1$/read_only=1\nsuper_read_only=1/' mysql/slave1/my.cnf mysql/slave2/my.cnf
cat mysql/slave1/my.cnf mysql/slave2/my.cnf
```

Reiniciar y comprobar:

```bash
docker compose restart mysql-slave1 mysql-slave2
docker exec mysql-slave1 sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT @@read_only, @@super_read_only"' 2>/dev/null
docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3308 -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE no_debe_existir;"' 2>&1 | grep -i read-only
./scripts/verify-replication.sh
```

- Resultado esperado: `1 1`, un error de `-super-read-only` al escribir por el 3308, y ambos esclavos en `OK`.

| Ajuste | Bloquea usuarios normales | Bloquea a `root` | Bloquea la replicación |
| --- | --- | --- | --- |
| `read_only=1` | Sí | No | No |
| `super_read_only=1` | Sí | Sí | No |

---

# Cómo funciona el balanceo implementado

## Método: `least_conn`

Cada conexión **nueva** va al esclavo con menos conexiones activas en ese momento. Si hay empate, se alternan.

| Situación | Conexión nueva va a |
| --- | --- |
| slave1 = 4, slave2 = 2 | slave2 (pasa a 3) |
| slave1 = 4, slave2 = 3 | slave2 (pasa a 4) |
| slave1 = 4, slave2 = 4 | Desempate por turnos |

## Por qué se eligió

| Método | Directiva | Cómo decide | Cuándo conviene |
| --- | --- | --- | --- |
| Least connections (elegido) | `least_conn;` | Esclavo con menos conexiones activas | Conexiones largas y desiguales (típico de MySQL) |
| Hash por cliente | `hash $remote_addr consistent;` | El mismo cliente siempre al mismo esclavo | Cuando se necesita pegajosidad (sticky) |
| Random two | `random two least_conn;` | Elige 2 al azar y toma el de menos conexiones | Muchos nodos o varios NGINX |
| Round robin | (por defecto) | Turnos en orden | Conexiones homogéneas |

Se descartó `hash $remote_addr` porque en las pruebas todas las conexiones salen desde la misma IP (`mysql-master`, `172.18.0.2`), así que todo iría a un único esclavo.

## Puntos importantes

- **El reparto es por conexión, no por consulta.** Una conexión abierta usa siempre el mismo esclavo.
- **NGINX nunca mueve una conexión existente.** Con un pool de 10 conexiones abiertas todo el día, quedan 5 y 5. Si un esclavo se reinicia, sus conexiones se pierden y se reabren; las que nazcan mientras está caído van al otro esclavo, y la distribución puede quedar desbalanceada hasta que el pool recicle conexiones.
- **Tolerancia a fallos:** con `max_fails=2 fail_timeout=10s`, tras 2 fallos en 10 s el esclavo se retira del reparto 10 s. Pasado ese tiempo NGINX lo vuelve a probar y, si responde, se reincorpora.
- **Con conexiones instantáneas**, los contadores quedan en 0 y el desempate hace que el reparto se vea alterno. El efecto real de `least_conn` se ve con conexiones simultáneas.

---

# Problemas comunes y solución

## 1. MySQL ignora los `my.cnf`: `World-writable config file ... is ignored`

- **Síntoma:** `verify-replication.sh` daba "NO DISPONIBLE" en el maestro y "sin estado de replicación" en los esclavos, aunque `docker compose ps` mostraba los tres contenedores `healthy`.
- **Causa:** el proyecto estaba en `/mnt/c/.../OneDrive`. WSL muestra esos archivos con permisos 777 y MySQL ignora los `.cnf` escribibles por todos. Los nodos arrancaron sin GTID, sin `server-id` y sin `read_only`. El healthcheck (`mysqladmin ping`) solo comprueba que el servidor responde, por eso seguía `healthy`.
- **Solución:** mover el proyecto al sistema de archivos de WSL (`~/proyecto-mysql-lb`), manteniendo el nombre de carpeta para reutilizar los volúmenes.

```bash
cp -a /mnt/c/Users/david/OneDrive/Escritorio/proyecto-mysql-lb ~/proyecto-mysql-lb
cd /mnt/c/Users/david/OneDrive/Escritorio/proyecto-mysql-lb && docker compose down
cd ~/proyecto-mysql-lb
chmod 644 mysql/*/my.cnf
chmod +x scripts/*.sh mysql/slave-init/*.sh
docker compose up -d
```

- **Importante:** `docker compose down` **sin `v`**. Con `v` se borraría el volumen del maestro.

## 2. Maestro con `gtid_executed` vacío y esclavos sin replicación configurada

- **Síntoma:** tras mover el proyecto, el `.cnf` ya se aplicaba (`gtid_mode=ON`, `server_id=1`), pero el script seguía en "NO DISPONIBLE" y `SHOW SLAVE STATUS` salía vacío.
- **Causa:** los volúmenes se inicializaron mientras el `.cnf` se ignoraba. El maestro no tenía transacciones con GTID y el script `01-replication.sh` (que solo corre con el volumen vacío) no dejó la replicación configurada.
- **Solución:** configurar la replicación a mano en cada esclavo y generar una transacción en el maestro.

```bash
for s in mysql-slave1 mysql-slave2; do
  docker exec $s sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "STOP SLAVE; CHANGE MASTER TO MASTER_HOST=\"mysql-master\", MASTER_USER=\"$MYSQL_REPL_USER\", MASTER_PASSWORD=\"$MYSQL_REPL_PASSWORD\", MASTER_AUTO_POSITION=1, GET_MASTER_PUBLIC_KEY=1; START SLAVE;"' 2>/dev/null
done
```

## 3. Base `prueba_replicacion` huérfana en el maestro

- **Síntoma:** quedaba una base de prueba creada sin GTID.
- **Causa:** se creó cuando el `.cnf` se ignoraba. Un `DROP` normal se registraría en el binlog y los esclavos, que no tienen esa base, detendrían su hilo SQL con error.
- **Solución:** borrarla sin registrar en el binlog.

```bash
docker exec mysql-master sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SET SESSION sql_log_bin=0; DROP DATABASE prueba_replicacion;"' 2>/dev/null
```

## 4. `host not found in upstream "mysql-master:3306"` al ejecutar `nginx -t`

- **Síntoma:** `docker run --rm ... nginx -t` falló con `[emerg] host not found in upstream`.
- **Causa:** NGINX resuelve los nombres de los upstream al validar y al arrancar. Un `docker run` suelto no está en la red `mysql_net`, así que Docker no sabe resolver `mysql-master`. No era un error de sintaxis.
- **Solución:** ejecutar la validación conectado a la red del proyecto con `-network proyecto-mysql-lb_mysql_net` (Paso 4). Con `docker compose up`, `depends_on` garantiza que los nodos existan antes de arrancar NGINX.

## 5. Todas las lecturas iban a un solo esclavo (falta de `zone`)

- **Síntoma:** en las pruebas A y B, todas las conexiones al puerto 3308 devolvían `server_id = 2` y el log mostraba siempre `172.18.0.3`, aunque slave2 estaba sano.
- **Causa:** el upstream no tenía `zone`. Con `worker_processes auto` hay varios workers y, sin memoria compartida, cada uno lleva sus propios contadores. Cada conexión nueva veía contadores en 0 y elegía el primer servidor de la lista.
- **Solución:** añadir `zone mysql_read 64k;` al upstream de lectura y recargar con `nginx -s reload`. Después el reparto salió `3, 2, 3, 2, 3, 2` y las conexiones largas fueron a IPs distintas.

## 6. `root` puede escribir en un esclavo por el puerto de lectura

- **Síntoma / riesgo:** `read_only=1` no bloquea a usuarios con privilegio SUPER. Una escritura de `root` por el 3308 entraría en el esclavo con un GTID local (transacción errática) y podría romper la replicación.
- **Solución:** `super_read_only=1` en los `my.cnf` de los esclavos (Paso 11). Para la demo, escribir siempre por el 3307.

## 7. Detalles que no son errores

- `with-stream` aparece 4 veces en `nginx -V | grep -o`: es normal, cada coincidencia se imprime por separado.
- `80/tcp` en `nginx-lb` dentro de `docker ps`: solo está declarado por la imagen, no está publicado al host.
- Mensajes `10-listen-on-ipv6...` y `20-envsubst...` al arrancar NGINX: scripts de arranque de la imagen, no afectan a la configuración.
- El log de stream se escribe al **cerrar** la conexión, no al abrirla.

## Reglas de seguridad del proyecto

- Nunca usar `docker compose down -v`: borra también el volumen del maestro.
- Trabajar siempre desde `~/proyecto-mysql-lb` y no desde `/mnt/c`.
- Los scripts de `mysql/slave-init/` solo corren con el volumen vacío.

---

# Checklist de finalización

- [x]  Contenedor NGINX levantado con el módulo stream habilitado
- [x]  Puerto de escritura (3307) apuntando exclusivamente al maestro
- [x]  Puerto de lectura (3308) repartiendo conexiones entre los esclavos
- [x]  Solo NGINX expone puertos hacia el host; los nodos MySQL permanecen en la red interna
- [x]  Prueba de `@@server_id` / `@@hostname` desde varias conexiones: responden ambos esclavos
- [x]  Prueba de escrituras: solo llegan al maestro (`nodo = 1`) y se replican a los esclavos
- [x]  README actualizado con la configuración de NGINX y cómo probarla
- [x]  Extras: prueba de tolerancia a fallos y `super_read_only=1`