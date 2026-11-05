# Balanceo de carga de lectura MySQL

Replicación maestro-esclavo con NGINX (modo stream), todo en Docker Compose.
No requiere instalar nada en el host salvo Docker y Docker Compose.

## Arquitectura

### Objetivo

Repartir las **lecturas** entre varios nodos MySQL esclavos usando NGINX en modo stream (balanceo TCP), mientras que las **escrituras** van al nodo maestro. Los esclavos copian los cambios del maestro mediante replicación basada en binlog con GTID.

### Diagrama

```
                 Host (solo Docker, nada más instalado)
 ┌───────────────────────────────────────────────────────────────┐
 │                  Red Docker: mysql_net (bridge)               │
 │                                                               │
 │  Escrituras ──► :3307 ─┐                                      │
 │  Lecturas   ──► :3308 ─┤   ┌─────────────────┐                │
 │  (únicos puertos       └──►│    nginx-lb     │  [Fase 3 ✔]    │
 │   publicados al host)      │  NGINX stream   │                │
 │                            └───┬─────────┬───┘                │
 │                  :3307 (write) │         │ :3308 (read,       │
 │                                │         │  least_conn)       │
 │                                │   ┌─────┴───────┐            │
 │                                │   ▼             ▼            │
 │                                │ ┌───────────┐ ┌───────────┐  │
 │                                │ │mysql-slave1│ │mysql-slave2│ │
 │                                │ │server-id 2│ │server-id 3│  │
 │                                │ │ read-only │ │ read-only │  │
 │                                │ └─────▲─────┘ └─────▲─────┘  │
 │                                │       │ replicación │        │
 │                                ▼       │ (GTID)      │        │
 │                         ┌──────────────┴─────────────┘        │
 │                         │  mysql-master                        │
 │                         │  server-id = 1, binlog + GTID        │
 │                         │  puerto 3306 (solo interno)          │
 │                         └──────────────┬──────────────         │
 │                                        │                       │
 │                          volumen: mysql_master_data            │
 └───────────────────────────────────────────────────────────────┘
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
    └── verify-replication.sh
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
| 4 a 6 | ... | Pendiente |
