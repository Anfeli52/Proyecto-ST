# 2.1. Fase 1 — Infraestructura + Replicación: Maestro (Eddie)

## 1. Resumen de lo construido

### Qué se construyó

- Un repositorio con una estructura clara para que las 6 fases del equipo convivan en el mismo proyecto.
- Un `docker-compose.yml` con una **red interna** (`mysql_net`) y un **volumen persistente** (`mysql_master_data`).
- Un contenedor **`mysql-master`** (MySQL 8.0) con su propio `my.cnf`: `server-id = 1`, binlog activado, formato `ROW` y GTID habilitado.
- Un usuario **`replicador`** con permisos mínimos (`REPLICATION SLAVE`, `REPLICATION CLIENT`) que usarán los esclavos.
- Credenciales generadas aleatoriamente y guardadas en un `.env` que **no se sube** a git (con un `.env.example` como plantilla).
- Verificación de que el maestro es accesible desde otro contenedor de la red interna y **no** está expuesto al host.

### Por qué se hizo así

| Decisión | Motivo |
| --- | --- |
| Binlog + `server-id` único | Los esclavos copian los cambios leyendo el binlog; cada servidor necesita una identidad distinta |
| GTID activado | Cada transacción tiene un identificador global, así el esclavo no necesita saber "archivo X, posición Y" |
| `binlog_format = ROW` | Replica las filas modificadas, evitando resultados distintos entre servidores (por ejemplo con `NOW()` o `RAND()`) |
| Volumen con nombre | Los datos sobreviven al borrado del contenedor |
| Red bridge propia | Los contenedores se encuentran por nombre de servicio (`mysql-master`) gracias al DNS interno de Docker |
| Sin `ports:` en el maestro | Solo es accesible desde la red interna (menor superficie de ataque) |
| Usuario con mínimo privilegio | Si se compromete un esclavo, no se compromete el maestro |
| Contraseñas en `.env` fuera de git | Ningún secreto en el repositorio |

---

## 2. Arquitectura resultante

```
              Host (solo Docker y Docker Compose)
 ┌──────────────────────────────────────────────────────────┐
 │          Red Docker: proyecto-mysql-lb_mysql_net         │
 │                      (driver: bridge)                    │
 │                                                          │
 │   [Fases siguientes: esclavos y NGINX stream]            │
 │            │                                             │
 │            │ resuelven "mysql-master" por DNS interno    │
 │            ▼                                             │
 │     ┌───────────────────────────┐                        │
 │     │        mysql-master       │                        │
 │     │  mysql:8.0                │                        │
 │     │  server-id = 1            │                        │
 │     │  binlog (ROW) + GTID      │                        │
 │     │  usuario: replicador      │                        │
 │     │  puerto 3306 (solo red    │                        │
 │     │  interna, sin publicar)   │                        │
 │     └─────────────┬─────────────┘                        │
 │                   │                                      │
 │        /var/lib/mysql  ◄── volumen: mysql_master_data    │
 │        /etc/mysql/conf.d/my.cnf ◄── ./mysql/master/my.cnf│
 │                                       (solo lectura)     │
 └──────────────────────────────────────────────────────────┘
        ▲
        └── El puerto 3306 NO está expuesto al host
```

Estructura del repositorio:

```
proyecto-mysql-lb/
├── docker-compose.yml
├── .env               (local, ignorado por git)
├── .env.example       (plantilla sin secretos)
├── .gitignore
├── README.md
└── mysql/
    └── master/
        └── my.cnf
```

---

## 3. Archivos de configuración finales

### `.gitignore`

```
.env
```

### `.env.example`

```
MYSQL_ROOT_PASSWORD=cambiar_por_valor_generado
MYSQL_REPL_USER=replicador
MYSQL_REPL_PASSWORD=cambiar_por_valor_generado
```

### `mysql/master/my.cnf`

```
[mysqld]
server-id                = 1
log_bin                  = mysql-bin
binlog_format            = ROW
gtid_mode                = ON
enforce_gtid_consistency = ON
```

| Opción | Qué hace |
| --- | --- |
| `[mysqld]` | Sección del servidor MySQL; las opciones deben ir bajo este encabezado |
| `server-id = 1` | Identidad única del maestro en la topología |
| `log_bin = mysql-bin` | Activa el binlog; `mysql-bin` es el prefijo de los archivos |
| `binlog_format = ROW` | Registra las filas cambiadas en lugar de la sentencia SQL |
| `gtid_mode = ON` | Activa los identificadores globales de transacción |
| `enforce_gtid_consistency = ON` | Prohíbe sentencias que no se pueden etiquetar de forma segura con GTID (requisito de `gtid_mode`) |

### `docker-compose.yml`

```yaml
services:
  mysql-master:
    image: mysql:8.0
    container_name: mysql-master
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_REPL_USER: ${MYSQL_REPL_USER}
      MYSQL_REPL_PASSWORD: ${MYSQL_REPL_PASSWORD}
    volumes:
      - mysql_master_data:/var/lib/mysql
      - ./mysql/master/my.cnf:/etc/mysql/conf.d/my.cnf:ro
    networks:
      - mysql_net
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p\"$$MYSQL_ROOT_PASSWORD\" --silent"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s

networks:
  mysql_net:
    driver: bridge

volumes:
  mysql_master_data:
```

| Elemento | Qué hace |
| --- | --- |
| `image: mysql:8.0` | Fija la versión mayor para evitar cambios inesperados con `latest` |
| `container_name` | Nombre fijo del contenedor, cómodo para `docker exec` |
| `MYSQL_ROOT_PASSWORD: ${...}` | La imagen fija la contraseña de root al inicializar; Compose toma el valor del `.env` |
| `MYSQL_REPL_USER` / `MYSQL_REPL_PASSWORD` | La imagen las ignora; las usamos desde dentro del contenedor para crear el usuario de replicación |
| `mysql_master_data:/var/lib/mysql` | Conecta el volumen con el directorio de datos de MySQL |
| `./mysql/master/my.cnf:...:ro` | Monta el `my.cnf` en la carpeta que MySQL lee al arrancar; `:ro` = solo lectura |
| `networks` | Conecta el servicio a la red interna |
| `healthcheck` | Comprueba con `mysqladmin ping` que MySQL realmente responde; `$$` evita que Compose resuelva la variable (la resuelve el shell dentro del contenedor) |
| Sin `ports:` | El maestro no se publica al host |

---

## 4. Comandos ejecutados, en orden

### Paso 1: Estructura del repositorio

#### 1.1 Crear carpetas, archivos y repositorio

```bash
mkdir proyecto-mysql-lb
cd proyecto-mysql-lb
mkdir -p mysql/master
touch docker-compose.yml .env .gitignore mysql/master/my.cnf
git init
```

- `mkdir`: crea una carpeta.
- `mkdir -p`: crea también las carpetas intermedias y no da error si ya existen.
- `cd`: entra a la carpeta del proyecto.
- `touch`: crea archivos vacíos.
- `git init`: inicializa el repositorio git local.

#### 1.2 Generar una contraseña aleatoria

```bash
openssl rand -hex 24
```

- `openssl rand`: genera bytes aleatorios criptográficamente seguros.
- `hex`: los imprime en hexadecimal (solo `0-9a-f`), evitando caracteres que rompen el `.env` o el cliente MySQL.
- `24`: 24 bytes, que equivalen a 48 caracteres.

Alternativa sin openssl instalado en el host:

```bash
docker run --rm alpine/openssl rand -hex 24
```

- `-rm`: elimina el contenedor al terminar.

#### 1.3 Crear el `.env` con contraseñas aleatorias

```bash
cat > .env <<EOF
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 24)
MYSQL_REPL_USER=replicador
MYSQL_REPL_PASSWORD=$(openssl rand -hex 12)
EOF
chmod 600 .env
```

- `cat > .env <<EOF ... EOF`: *here-document*; escribe en `.env` todo lo que hay entre los dos `EOF`.
- `$(...)`: ejecuta el comando interno y pega su resultado; por eso cada contraseña es distinta.
- `chmod 600`: solo el dueño puede leer y escribir el archivo.

#### 1.4 Crear la plantilla `.env.example`

```bash
cat > .env.example <<EOF
MYSQL_ROOT_PASSWORD=cambiar_por_valor_generado
MYSQL_REPL_USER=replicador
MYSQL_REPL_PASSWORD=cambiar_por_valor_generado
EOF
```

- Misma técnica de *here-document*, pero con valores de ejemplo. Este archivo sí se sube a git para que cualquiera sepa qué variables debe definir.

### Paso 2: Red y volúmenes

#### 2.1 Validar el `docker-compose.yml`

```bash
docker compose config
```

- Lee el compose, resuelve las variables del `.env` y muestra el resultado final. Funciona como validador de sintaxis sin levantar nada.
- Con solo red y volumen declarados, la salida fue `services: {}`: es correcto, porque Compose omite redes y volúmenes que ningún servicio usa.

### Paso 3: Contenedor maestro

#### 3.1 Permisos del `my.cnf`

```bash
chmod 644 mysql/master/my.cnf
```

- `644`: el dueño lee y escribe, los demás solo leen. MySQL ignora un `my.cnf` con permisos de escritura para "otros".

#### 3.2 Validar y levantar el servicio

```bash
docker compose config
docker compose up -d
```

- `up`: crea (si no existen) y arranca la red, el volumen y el contenedor.
- `d` (*detached*): lo deja en segundo plano.

#### 3.3 Revisar estado y logs

```bash
docker compose ps
docker compose logs mysql-master
```

- `ps`: lista los servicios y su estado; se espera `healthy`.
- `logs`: muestra la salida del contenedor; se busca `ready for connections`.

#### 3.4 Entrar al cliente MySQL del contenedor

```bash
docker exec -it mysql-master sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'
```

- `docker exec`: ejecuta un comando en un contenedor que ya está corriendo.
- `i`: mantiene la entrada abierta; `t`: asigna una terminal; juntos (`it`) dan una sesión interactiva.
- `sh -c '...'`: ejecuta un shell dentro del contenedor; las comillas simples hacen que `$MYSQL_ROOT_PASSWORD` se resuelva allí.
- `uroot`: usuario root. `p"..."`: contraseña pegada al flag.

Consultas para comprobar que el `my.cnf` se aplicó:

```sql
SHOW VARIABLES LIKE 'server_id';
SHOW VARIABLES LIKE 'log_bin';
SHOW VARIABLES LIKE 'gtid_mode';
SHOW MASTER STATUS;
```

- `SHOW VARIABLES LIKE '...'`: consulta el valor actual de una variable del servidor.
- `SHOW MASTER STATUS`: muestra el archivo de binlog actual y su posición, lo que confirma que el maestro registra cambios.
- Resultado esperado: `server_id = 1`, `log_bin = ON`, `gtid_mode = ON` y un archivo `mysql-bin.00000X`.

### Paso 4: Usuario de replicación

#### 4.0 Aplicar las variables nuevas al contenedor

Tras añadir `MYSQL_REPL_USER` y `MYSQL_REPL_PASSWORD` al bloque `environment`:

```bash
docker compose up -d
```

- Como la configuración cambió, Compose recrea el contenedor. Los datos se conservan porque viven en el volumen.

#### 4.1 Crear el usuario

```bash
docker exec mysql-master sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER IF NOT EXISTS \"$MYSQL_REPL_USER\"@\"%\" IDENTIFIED BY \"$MYSQL_REPL_PASSWORD\";"'
```

- `e "..."`: ejecuta la sentencia SQL y sale, sin abrir sesión interactiva.
- `CREATE USER IF NOT EXISTS`: crea el usuario solo si no existe, así el comando es repetible.
- `\"...\"`: comillas dobles escapadas dentro del string del shell.
- `@"%"`: host desde el que puede conectarse. `%` = cualquier host; es necesario porque los esclavos llegan desde otras IPs de la red de Docker (con `localhost` solo funcionaría dentro del propio maestro).
- `IDENTIFIED BY`: define la contraseña del usuario.

#### 4.2 Otorgar permisos mínimos

```bash
docker exec mysql-master sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO \"$MYSQL_REPL_USER\"@\"%\";"'
```

- `GRANT ... ON *.* TO`: asigna permisos. `.*` = todas las bases y tablas; los permisos de replicación son globales y MySQL no permite limitarlos a una base.
- `REPLICATION SLAVE`: permite leer el binlog del maestro (lo que hace un esclavo para copiar).
- `REPLICATION CLIENT`: permite consultar el estado de la replicación (`SHOW MASTER STATUS`).

#### 4.3 Verificar

```bash
docker exec mysql-master sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT user, host FROM mysql.user WHERE user=\"$MYSQL_REPL_USER\"; SHOW GRANTS FOR \"$MYSQL_REPL_USER\"@\"%\";"'
```

- `mysql.user`: tabla interna con los usuarios y su host permitido.
- `SHOW GRANTS FOR`: lista los permisos del usuario.
- Resultado obtenido: usuario `replicador` con host `%` y el grant `REPLICATION SLAVE, REPLICATION CLIENT ON *.*`, sin nada más.

### Paso 5: Verificar acceso desde la red interna

#### 5.1 Ver el nombre real de la red

```bash
docker network ls
```

- Lista las redes de Docker. Compose antepone el nombre del proyecto: la red se llama `proyecto-mysql-lb_mysql_net`.

#### 5.2 Conectarse como `replicador` desde otro contenedor

```bash
docker run --rm --network proyecto-mysql-lb_mysql_net --env-file .env mysql:8.0 \
  sh -c 'mysql -h mysql-master -u"$MYSQL_REPL_USER" -p"$MYSQL_REPL_PASSWORD" -e "SELECT CURRENT_USER(); SHOW MASTER STATUS;"'
```

- `-rm`: elimina el contenedor al terminar.
- `-network`: lo conecta a la red del proyecto, para que el DNS interno resuelva `mysql-master`.
- `-env-file .env`: carga las variables del `.env` dentro de este contenedor.
- `mysql:8.0`: reutiliza la imagen ya descargada; solo se necesita su cliente `mysql`.
- `h mysql-master`: el host es el nombre del servicio, tal como lo usarán los esclavos.
- Resultado esperado: `replicador@%` y el estado del binlog. Prueba resolución de nombre, conectividad al puerto 3306, autenticación y el permiso `REPLICATION CLIENT`.

#### 5.3 Prueba negativa de permisos mínimos

```bash
docker run --rm --network proyecto-mysql-lb_mysql_net --env-file .env mysql:8.0 \
  sh -c 'mysql -h mysql-master -u"$MYSQL_REPL_USER" -p"$MYSQL_REPL_PASSWORD" -e "CREATE DATABASE prueba;"'
```

- Debe **fallar** con `ERROR 1044 ... Access denied`, lo que confirma que el usuario no puede hacer nada más allá de replicar.

#### 5.4 Confirmar que el puerto no está expuesto al host

```bash
docker compose ps
```

## 5. Notas para las siguientes fases

- **Nombre del maestro en la red:** `mysql-master`, puerto `3306`.
- **Usuario de replicación:** el definido en `MYSQL_REPL_USER` (`replicador`), con la contraseña de `MYSQL_REPL_PASSWORD` del `.env`.
- **Identificadores de servidor:** el maestro usa `server-id = 1`; los esclavos deben usar valores distintos (2, 3, ...).
- **GTID:** está activado en el maestro; los esclavos deben usar replicación con auto-posicionamiento.
- **Autenticación `caching_sha2_password`:** es el plugin por defecto en MySQL 8.0. Para replicar sin SSL, el esclavo debe añadir `GET_SOURCE_PUBLIC_KEY=1` (o `GET_MASTER_PUBLIC_KEY=1`, según la versión) en su `CHANGE REPLICATION SOURCE TO`; sin esa opción habrá un error de autenticación aunque la contraseña sea correcta.
- **Red:** todos los servicios nuevos deben unirse a `mysql_net`.
- **Contraseña de root:** solo se aplica al crear el volumen. Para empezar de cero: `docker compose down -v`.