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

## Benchmark mixto y con nodo caído (Fase 6)

Completa la Fase 5 con cargas de lectura/escritura y con un esclavo caído. Reutiliza el usuario `sbtest` y el dataset
de la Fase 5. Se reproduce todo con un solo comando (unos 9 minutos con los valores por defecto):

```bash
./scripts/benchmark-mixto.sh               # 10 hilos, 60 s por prueba (8 lectura + 2 escritura en la dividida)
./scripts/benchmark-mixto.sh -t 20 -d 30   # otra carga; -w N cambia los hilos de escritura
```

El script mide, con los mismos hilos y duración, los escenarios de la tabla, **apaga `mysql-slave1` por su cuenta**
para los escenarios C y lo vuelve a encender al terminar (también con `Ctrl+C`). Guarda los logs crudos y `resumen.csv`
en `resultados/fase6/`. Las escrituras de `oltp_write_only`/`oltp_read_write` modifican filas de `sbtest1` pero no
cambian su número (1.000.000), así que el dataset sigue siendo válido para repetir las pruebas.

**Por qué hay una prueba "dividida":** NGINX trabaja en capa 4 y no puede repartir un `INSERT` ni un `SELECT` según su
contenido, y `oltp_read_write` usa una única conexión por hilo. Con él solo se puede apuntar al 3307 (todo al maestro).
Para imitar a una aplicación real que usa los dos puertos, la prueba dividida lanza a la vez 8 hilos
`oltp_read_only` contra el 3308 y 2 hilos `oltp_write_only` contra el 3307.

### Resultados (10 hilos, 60 s, 0 errores en todas las pruebas)

Medidos en un equipo de 8 núcleos y 7,4 GB de RAM compartidos por todos los contenedores. Valores de la corrida 2
(la corrida 1 quedó en `resultados/fase6-corrida1/` y difiere menos de un 12 %).

| Esc. | Escenario | TPS | QPS | avg (ms) | p95 (ms) |
|---|---|---|---|---|---|
| A1 | Lectura vía NGINX :3308 (2 esclavos) | 768 | 12.295 | 13,00 | 18,61 |
| A2 | Lectura directo al maestro (sin proxy) | 2.025 | 32.405 | 4,93 | 10,09 |
| A3 | Lectura directo a 1 esclavo (sin proxy) | 2.139 | 34.231 | 4,67 | 8,58 |
| B1 | Mixta `oltp_read_write` vía :3307 (todo al maestro) | 140 | 2.807 | 71,16 | 106,75 |
| B2 | Mixta dividida: lecturas (8 hilos) vía :3308 | 557 | 8.913 | 14,35 | 26,20 |
| B2 | Mixta dividida: escrituras (2 hilos) vía :3307 | 32 | 194 | 61,94 | 118,92 |
| C1 | Lectura vía NGINX con **slave1 caído** | 776 | 12.424 | 12,87 | 18,28 |
| C2 | Mixta dividida con slave1 caído: lecturas | 560 | 8.958 | 14,28 | 27,66 |
| C2 | Mixta dividida con slave1 caído: escrituras | 43 | 259 | 46,40 | 66,84 |

Para comparar con la Fase 5 (otro equipo, 12 núcleos) mira la tabla de la sección anterior: allí la lectura vía NGINX
rindió 5.174 TPS y directo a un esclavo 8.014 TPS. Los valores absolutos no son comparables entre equipos; sí lo es la
proporción entre escenarios del mismo equipo.

Extras medidos en el mismo script:

| Medición | Resultado |
|---|---|
| Retraso de replicación bajo escrituras (máx. `Seconds_Behind_Master`) | 11 s (slave1) y 6 s (slave2) en B2; 8 s y 3 s en C2 |
| Puesta al día de slave1 tras volver (GTID) | 7 s después de ~60 s de escrituras con slave1 caído |
| Lectura directa a slave1, slave2 y maestro (20 s, diagnóstico) | 2.076 / 2.099 / 2.044 TPS: los tres nodos rinden igual |

### Conclusiones preliminares

- **El balanceo no mejoró el throughput en este entorno; lo redujo.** Vía NGINX se obtuvo ~768 TPS frente a ~2.100 directo
  a un nodo (−63 %; en la Fase 5, −35 %). Los tres nodos rinden igual, así que el cuello de botella es el salto por el
  proxy, no MySQL. Además, dos esclavos (A1) rinden igual que uno solo (C1): todo comparte la misma CPU, por lo que un
  segundo esclavo no añade capacidad real.
- **Con un esclavo caído el rendimiento casi no cambió** (C1 ≈ A1, +1 %; las lecturas de C2 ≈ B2). Se explica porque el
  sistema está limitado por el proxy y la CPU compartida, no por la cantidad de esclavos. Para las lecturas el costo de la
  caída está en la latencia de detección (Fase 4: 3–5 s para los primeros clientes), que aquí quedó fuera de la medición
  porque se hizo un calentamiento de 15 s con el nodo ya apagado. Las escrituras en C2 salieron más rápidas (43 vs 32 TPS)
  porque con un esclavo menos hay menos replicación compitiendo por la CPU.
- **Las escrituras son lo más caro**: la mixta completa (B1) llega a 140 TPS con ~71 ms de latencia media, y las 2 escrituras
  de B2 apenas 32 TPS. Todas pasan por el único maestro, que además hace `fsync` del binlog en cada commit.
- **Consistencia eventual visible**: bajo escritura continua los esclavos van entre 3 y 11 s por detrás del maestro. Una
  aplicación que lea justo después de escribir puede no ver su propio cambio si lee por el 3308.
- **Alta disponibilidad de lectura sí se cumple**: 0 errores en todas las pruebas, incluida la que tuvo slave1 apagado,
  y slave1 se puso al día solo al volver.
- **Limitaciones**: una máquina, dos corridas por escenario, cliente y servidores en el mismo host, un solo dataset de
  1 tabla. Los absolutos dependen del equipo; la comparación es válida porque todo se midió en las mismas condiciones.

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
    ├── benchmark-lectura.sh
    └── benchmark-mixto.sh
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
| 4. Health checks y tolerancia a fallos | Cesar Andrés Díaz Jimenez | Completa |
| 5. Sysbench: preparación y pruebas de solo lectura | Andrés Felipe Medina Díaz | Completa |
| 6. Sysbench: pruebas mixtas y consolidación de métricas | Juan David Agudelo Diago | Completa |
