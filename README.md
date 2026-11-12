# Balanceo de carga de lectura MySQL

Replicación maestro-esclavo con NGINX (modo stream), todo en Docker Compose.
No requiere instalar nada en el host salvo Docker y Docker Compose.

## Arquitectura

### Objetivo

Repartir las **lecturas** entre varios nodos MySQL esclavos usando NGINX en modo stream (balanceo TCP), mientras que las **escrituras** van al nodo maestro. Los esclavos copian los cambios del maestro mediante replicación basada en binlog con GTID.

### Diagrama

```
                 Host (solo Docker, nada más instalado)
 ┌───────────────────────────────────────────────────────────────────┐
 │                   Red Docker: mysql_net (bridge)                  │
 │                                                                   │
 │  Escrituras ──► :3307 ─┐                                          │
 │  Lecturas   ──► :3308 ─┤    ┌─────────────────┐                   │
 │  (únicos puertos       └───►│    nginx-lb     │  [Fase 3 ✔]      │
 │   publicados al host)       │  NGINX stream   │                   │
 │                             └───┬─────────┬───┘                   │
 │  ┌───────────────┐  3307/3308   │         │                       │
 │  │   sysbench    │ ─────────────┘         │ :3308 (read,          │
 │  │ perfil "bench"│  prepare → 3307        │  least_conn)          │
 │  │ [Fase 5 ✔]   │  run     → 3308        │                       │
 │  └───────────────┘                  ┌─────┴───────┐               │
 │                                     ▼             ▼               │
 │                :3307 (write)  ┌────────────┐ ┌────────────┐       │
 │                      │        │mysql-slave1│ │mysql-slave2│       │
 │                      │        │server-id 2 │ │server-id 3 │       │
 │                      │        │ read-only  │ │ read-only  │       │
 │                      │        └─────▲──────┘ └─────▲──────┘       │
 │                      ▼              │ replicación  │              │
 │               ┌──────────────────── │ (GTID) ──────┘              │
 │               │  mysql-master                                     │
 │               │  server-id = 1, binlog + GTID                     │
 │               │  puerto 3306 (solo interno)                       │
 │               └──────────────────────┬─────────────               │
 │                                      │                            │
 │                        volumen: mysql_master_data                 │
 └───────────────────────────────────────────────────────────────────┘
```

### Componentes

| Componente | Función | Estado |
|---|---|---|
| `mysql-master` | Recibe escrituras y registra cada cambio en el binlog (`server-id=1`, GTID activado) | Completo (Fase 1) |
| Usuario `replicador` | Cuenta con permisos mínimos (`REPLICATION SLAVE`, `REPLICATION CLIENT`) que usan los esclavos | Completo (Fase 1) |
| `mysql_net` | Red interna: los contenedores se encuentran por nombre de servicio | Completo (Fase 1) |
| `mysql_master_data` | Volumen persistente: los datos sobreviven a `down`/`up` | Completo (Fase 1) |
| `mysql-slave1` / `mysql-slave2` | Copian al maestro y atienden lecturas (`server-id` 2 y 3, `read_only=1`, `super_read_only=1`) | Completo (Fase 2) |
| `nginx-lb` | NGINX en modo stream: puerto 3307 → maestro, puerto 3308 → esclavos con `least_conn` | Completo (Fase 3) |
| `sysbench` | Generador de carga para los benchmarks; solo corre bajo demanda (perfil `bench`) | Completo (Fase 5) |

### Decisiones de diseño

- **Solo NGINX publica puertos** (3307 y 3308). Los tres nodos MySQL solo exponen 3306 dentro de `mysql_net`.
- **Contraseñas fuera del repositorio**: se generan en el `.env` (ver sección de credenciales).
- **GTID** en lugar de posiciones de binlog: simplifica configurar los esclavos.
- **`binlog_format=ROW`**: replica los cambios de filas, evitando resultados distintos entre servidores.
- **`super_read_only=1` en los esclavos**: ni siquiera `root` puede escribir en ellos; solo recibe datos por replicación.
- **Dos puertos separados** (escritura/lectura): NGINX trabaja en capa 4 y no puede distinguir un `SELECT` de un `INSERT`, así que la aplicación elige el puerto.

## Replicación (esclavos)

Verificar el estado de la replicación en cualquier momento:

```bash
./scripts/verify-replication.sh
```

El script comprueba `Slave_IO_Running`, `Slave_SQL_Running`, `Seconds_Behind_Master`, los errores de IO/SQL y que los GTID del maestro estén contenidos en cada esclavo. Termina con código 0 si todo está bien y 1 si algo falla.

Los scripts de `mysql/slave-init/` solo se ejecutan cuando el volumen del
esclavo está vacío. Para reconfigurar un esclavo desde cero:

```bash
docker compose rm -sf mysql-slave1
docker volume rm <proyecto>_mysql_slave1_data
docker compose up -d
```

## Balanceo con NGINX (stream)

NGINX trabaja en la capa 4 (TCP): no interpreta SQL, solo reenvía conexiones.
Como no puede distinguir un `SELECT` de un `INSERT`, hay **dos puertos** y la
aplicación elige a cuál conectarse.

| Puerto (host) | Destino | Uso |
|---|---|---|
| `3307` | `mysql-master:3306` | Escrituras (siempre al maestro) |
| `3308` | `mysql-slave1:3306` / `mysql-slave2:3306` | Lecturas (balanceadas) |

### Algoritmo: `least_conn`

Cada conexión **nueva** va al esclavo con menos conexiones activas (si empatan,
se alternan). Se eligió porque las conexiones MySQL duran tiempos muy distintos.
El reparto es **por conexión, no por consulta**: una conexión abierta usa
siempre el mismo esclavo, y NGINX nunca la reubica.

Puntos clave de `nginx/nginx.conf`:

- `zone mysql_read 64k;` en el upstream es **obligatorio**: sin memoria compartida, cada
  worker de NGINX lleva sus propios contadores y `least_conn` no reparte
  (todo iba a un solo esclavo).
- `max_fails=2 fail_timeout=10s`: si un esclavo falla dos veces seguidas, se retira del reparto
  10 s y se reintenta con el otro. Cuando vuelve, se reincorpora solo.
- `depends_on` con `service_healthy` en el compose: NGINX resuelve los nombres al arrancar,
  así que los tres MySQL deben existir antes.

### Cómo probarlo

Los clientes se lanzan desde dentro de la red usando el contenedor del maestro.
`@@server_id` identifica el nodo (maestro=1, slave1=2, slave2=3).

```bash
# Lecturas: deben aparecer server_id 2 y 3
for i in 1 2 3 4 5 6; do
  docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3308 -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT @@hostname, @@server_id"' 2>/dev/null
done

# Escritura: debe devolver nodo = 1
docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3307 -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT @@server_id AS nodo"' 2>/dev/null

# Escritura por el puerto de lectura: debe fallar con --super-read-only
docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3308 -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE no_debe_existir;"' 2>&1 | grep -i read-only
```

Para ver `least_conn` con conexiones simultáneas, abre dos conexiones largas y luego una tercera:

```bash
for i in 1 2; do
  docker exec -d mysql-master sh -c 'mysql -h nginx-lb -P 3308 -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT @@server_id, SLEEP(30)"'
done
sleep 2
docker exec mysql-master sh -c 'mysql -h nginx-lb -P 3308 -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT @@server_id"' 2>/dev/null
```

Tolerancia a fallos: con slave1 parado, todo sale por slave2.

```bash
docker stop mysql-slave1
# ... repetir las lecturas: solo aparece server_id 3 ...
docker start mysql-slave1
./scripts/verify-replication.sh   # slave1 se pone al día solo
```

Log de NGINX (muestra el nodo destino de cada conexión **al cerrarse**):

```bash
docker logs nginx-lb 2>&1 | tail
```

### Advertencias

- Valida cambios de configuración dentro de la red del proyecto (fuera de ella
  los nombres no resuelven y da `host not found in upstream`):

  ```bash
  docker run --rm --network <proyecto>_mysql_net \
    -v "$PWD/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
    nginx:1.27 nginx -t
  docker exec nginx-lb nginx -s reload
  ```

- El proyecto debe vivir en el sistema de archivos de WSL (`~/...`), no en `/mnt/c`:
  MySQL ignora los `.cnf` con permisos 777 (`World-writable config file is ignored`)
  y los nodos arrancan sin GTID ni `server-id`.
- Nunca uses `docker compose down -v`: borra también el volumen del maestro.
- Para escribir, usa siempre el puerto 3307. La aplicación debería usar un usuario
  sin permisos de escritura en el puerto 3308.

## Benchmark con Sysbench

[Sysbench](https://github.com/akopytov/sysbench) genera carga artificial para medir el rendimiento. Aquí se usa el
script `oltp_read_only` (transacciones de solo lectura típicas de una aplicación web). Corre como servicio
`sysbench` del `docker-compose.yml`, bajo el perfil `bench`: **no se levanta con `docker compose up -d`**, solo
cuando se invoca con `docker compose run --rm sysbench <argumentos>`.

### 1. Preparación

El cliente de Sysbench es de MariaDB y no soporta `caching_sha2_password` (el método por defecto de MySQL 8;
da `error 2059`). Se crea un usuario dedicado con `mysql_native_password`, **en el maestro**, y la replicación lo
copia a los esclavos. Su contraseña es `SYSBENCH_PASSWORD` del `.env`.

```bash
set -a; . ./.env; set +a    # carga las variables del .env en la shell (bash/zsh)

docker exec mysql-master sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \"
  CREATE DATABASE IF NOT EXISTS sbtest;
  CREATE USER IF NOT EXISTS 'sbtest'@'%' IDENTIFIED WITH mysql_native_password BY '$SYSBENCH_PASSWORD';
  GRANT ALL ON sbtest.* TO 'sbtest'@'%';\""
```

### 2. Cargar el dataset (1.000.000 de filas)

Siempre por el puerto **3307** (maestro): los esclavos son `super_read_only`. La replicación lo copia a ambos.

```bash
docker compose run --rm sysbench oltp_read_only \
  --mysql-host=nginx-lb --mysql-port=3307 --mysql-user=sbtest --mysql-password=$SYSBENCH_PASSWORD \
  --mysql-db=sbtest --tables=1 --table-size=1000000 prepare
```

Comprobar que los tres nodos tienen todas las filas (debe dar 1000000 en cada uno):

```bash
./scripts/verify-replication.sh
for n in mysql-master mysql-slave1 mysql-slave2; do
  docker exec $n sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT COUNT(*) FROM sbtest.sbtest1"' 2>/dev/null
done
```

### 3. Benchmark de solo lectura (10 hilos, 60 s)

Por el puerto de lectura de NGINX (**3308**):

```bash
docker compose run --rm sysbench oltp_read_only \
  --mysql-host=nginx-lb --mysql-port=3308 --mysql-user=sbtest --mysql-password=$SYSBENCH_PASSWORD \
  --mysql-db=sbtest --tables=1 --table-size=1000000 \
  --threads=10 --time=60 --report-interval=10 run
```

Parámetros: `--threads` = conexiones/clientes simultáneos; `--time` = duración en segundos;
`--report-interval` = imprime TPS y latencia cada N s. Para la línea de comparación, la misma prueba directa a un
solo nodo: `--mysql-host=mysql-slave1 --mysql-port=3306`.

Métricas: **TPS** = transacciones completas por segundo; **QPS** = consultas por segundo (cada transacción tiene
varias); **latencia** = tiempo por transacción (promedio y percentil 95, el valor que no supera el 95 % de las
transacciones). Más TPS y menos latencia es mejor.

Para ver el reparto de `least_conn` durante la prueba (deben ser 5 y 5):

```bash
docker exec mysql-slave1 sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT COUNT(*) FROM information_schema.processlist WHERE user=\"sbtest\""' 2>/dev/null
docker exec mysql-slave2 sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT COUNT(*) FROM information_schema.processlist WHERE user=\"sbtest\""' 2>/dev/null
```

Para repetir la comparación completa (vía NGINX, directo a un nodo y, con `-u`, un solo esclavo vía NGINX) con un solo comando:

```bash
./scripts/benchmark-lectura.sh              # 10 hilos, 60 s por prueba
./scripts/benchmark-lectura.sh -t 64 -d 30  # otra carga
./scripts/benchmark-lectura.sh -u           # añade "1 esclavo vía NGINX"
```

Comprueba antes que el dataset está completo en los tres nodos y muestra una tabla con TPS, QPS y latencias.

Limpiar el dataset al terminar (por el puerto 3307): sustituye `run` por `cleanup`.

### 4. Resultados obtenidos

Solo lectura, 1 tabla de 1.000.000 de filas, 0 errores en todas las pruebas:

| Hilos | Vía NGINX (2 esclavos) | Vía NGINX (1 esclavo) | Directo a 1 esclavo |
|---|---|---|---|
| 10 (60 s) | 5174 TPS · avg 1,93 ms · p95 2,52 ms | 4927 TPS · avg 2,03 ms · p95 2,76 ms | 8014 TPS · avg 1,25 ms · p95 1,82 ms |
| 64 (30 s) | 5136 TPS · avg 12,45 ms · p95 23,10 ms | 5358 TPS · avg 11,94 ms · p95 23,52 ms | 7791 TPS · avg 8,21 ms · p95 17,63 ms |
| 128 (30 s) | 4873 TPS · avg 26,25 ms · p95 48,34 ms | 4977 TPS · avg 25,70 ms · p95 53,85 ms | 7321 TPS · avg 17,47 ms · p95 39,65 ms |

La columna "1 esclavo vía NGINX" se midió con un NGINX temporal que apuntaba solo a `mysql-slave1`.

### 5. Interpretación y limitaciones

- **El reparto funciona**: con 10 hilos hubo 5 conexiones en cada esclavo.
- **El proxy tiene un costo (~35 % de TPS)**: pasar por NGINX rinde menos que ir directo a un nodo.
- **Dos esclavos no superan a uno en este entorno**: todos los contenedores (MySQL, NGINX y Sysbench) comparten
  la CPU, RAM y disco del mismo host, así que un segundo esclavo no añade capacidad real, solo reparte la
  existente. El balanceo de lectura aumenta el rendimiento cuando cada esclavo corre en hardware distinto y un solo
  nodo es el cuello de botella.
- Más hilos no aumentan el TPS una vez saturado el servidor, solo suben la latencia.
- Los valores absolutos dependen de la máquina y de la carga del momento; la comparación es válida porque todas las
  pruebas usaron los mismos parámetros en el mismo equipo.

## Estructura del repositorio

```
├── docker-compose.yml
├── .env.example
├── mysql/
│   ├── master/my.cnf
│   ├── slave1/my.cnf
│   ├── slave2/my.cnf
│   └── slave-init/01-replication.sh
├── nginx/
│   └── nginx.conf
└── scripts/
    ├── verify-replication.sh
    ├── test-fase4-vivo.sh
    └── benchmark-lectura.sh
```

## Requisitos

- Docker y Docker Compose v2
- En Windows: WSL2 con el proyecto dentro del sistema de archivos de WSL (`~/`)

## Configuración de credenciales

Las contraseñas **no están en el repositorio**. Cada persona debe generar su propio `.env`:

1. Copia la plantilla o genera el archivo directamente:

   ```bash
   cat > .env <<EOF
   MYSQL_ROOT_PASSWORD=$(openssl rand -hex 24)
   MYSQL_REPL_USER=replicador
   MYSQL_REPL_PASSWORD=$(openssl rand -hex 12)
   EOF
   chmod 600 .env
   ```

   Sin openssl en el host: `docker run --rm alpine/openssl rand -hex 24`

2. Variables:

   | Variable | Para qué sirve |
   |---|---|
   | `MYSQL_ROOT_PASSWORD` | Administrador de los nodos MySQL |
   | `MYSQL_REPL_USER` | Usuario que usarán los esclavos para replicar |
   | `MYSQL_REPL_PASSWORD` | Contraseña de ese usuario |
   | `SYSBENCH_PASSWORD` | Contraseña del usuario `sbtest` (Fase 5). Genera con `echo "SYSBENCH_PASSWORD=$(openssl rand -hex 12)" >> .env` |

## Puesta en marcha

```bash
docker compose up -d
docker compose ps   # esperar a que los 4 servicios estén "Up" y los MySQL "healthy"
./scripts/verify-replication.sh
```

## Fases del proyecto

| Fase | Responsable | Estado |
|---|---|---|
| 1. Infraestructura + maestro | Eddie Santiago Delgado Campo | Completa |
| 2. Replicación: Esclavos + Verificación | Eddie Santiago Delgado Campo | Completa |
| 3. NGINX: Balanceo de lectura/escritura | Christian David Home Acero | Completa |
| 4. Health checks y tolerancia a fallos | Cesar Andŕes Díaz Jimenez | Completa |
| 5. Sysbench: preparación y pruebas de solo lectura | Andrés Felipe Medina Díaz | Completa |
| 6 | ... | Pendiente |
