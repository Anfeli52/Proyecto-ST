# Balanceo de carga de lectura MySQL

Replicación maestro-esclavo con NGINX (modo stream), todo en Docker Compose.
No requiere instalar nada en el host salvo Docker y Docker Compose

## Arquitectura

### Objetivo

Repartir las **lecturas** entre varios nodos MySQL esclavos usando NGINX en modo stream (balanceo TCP), mientras que las **escrituras** van al nodo maestro. Los esclavos copian los cambios del maestro mediante replicación basada en binlog con GTID.

### Diagrama

```
                  Host (solo Docker, nada más instalado)
 ┌──────────────────────────────────────────────────────────────┐
 │                    Red Docker: mysql_net (bridge)            │
 │                                                              │
 │   Clientes ──► ┌───────────────┐                             │
 │   (lecturas)   │ NGINX stream  │  [pendiente]                │
 │                └───────┬───────┘                             │
 │                 ┌──────┴───────┐                             │
 │                 ▼              ▼                             │
 │        ┌─────────────┐ ┌─────────────┐                       │
 │        │ mysql-slave1│ │ mysql-slave2│                       │
 │        └──────▲──────┘ └──────▲──────┘                       │
 │               │ replicación   │ (lee el binlog               │
 │               │  usuario: replicador                         │
 │               └───────┬───────┘                              │
 │                ┌──────┴───────┐                              │
 │                │ mysql-master │  server-id = 1  [Fase 1 ✔]   │
 │                │ binlog + GTID│  puerto 3306 (solo interno)  │
 │                └──────┬───────┘                              │
 │                       │                                      │
 │            volumen: mysql_master_data                        │
 └──────────────────────────────────────────────────────────────┘
```

### Componentes

| Componente | Función | Estado |
|---|---|---|
| `mysql-master` | Recibe escrituras y registra cada cambio en el binlog (`server-id=1`, GTID activado) | Completo (Fase 1) |
| Usuario `replicador` | Cuenta con permisos mínimos (`REPLICATION SLAVE`, `REPLICATION CLIENT`) que usarán los esclavos | Completo (Fase 1) |
| `mysql_net` | Red interna: los contenedores se encuentran por nombre de servicio | Completo (Fase 1) |
| `mysql_master_data` | Volumen persistente: los datos sobreviven a `down`/`up` | Completo (Fase 1) |
| Esclavos | Copian al maestro y atienden lecturas | Pendiente |
| NGINX stream | Reparte las conexiones de lectura entre los esclavos | Pendiente |

### Decisiones de diseño

- **Sin puertos publicados** en el maestro: solo es accesible desde la red interna.
- **Contraseñas fuera del repositorio**: se generan en el `.env` (ver sección de credenciales).
- **GTID** en lugar de posiciones de binlog: simplifica configurar los esclavos.
- **`binlog_format=ROW`**: replica los cambios de filas, evitando resultados distintos entre servidores.

## Replicación (esclavos)

Verificar el estado de la replicación en cualquier momento:

```bash
./scripts/verify-replication.sh
```

Los scripts de `mysql/slave-init/` solo se ejecutan cuando el volumen del
esclavo está vacío. Para reconfigurar un esclavo desde cero:

```bash
docker compose rm -sf mysql-slave1
docker volume rm <proyecto>_mysql_slave1_data
docker compose up -d
```

## Estructura del repositorio

```
├── docker-compose.yml
├── .env.example
└── mysql/
    └── master/my.cnf
```

## Requisitos

- Docker y Docker Compose v2

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
   | `MYSQL_ROOT_PASSWORD` | Administrador del maestro |
   | `MYSQL_REPL_USER` | Usuario que usarán los esclavos para replicar |
   | `MYSQL_REPL_PASSWORD` | Contraseña de ese usuario |

## Puesta en marcha

```bash
docker compose up -d
docker compose ps   # esperar a que esté "healthy"
```

## Fases del proyecto

| Fase | Responsable | Estado |
|---|---|---|
| 1. Infraestructura + maestro | Eddie Santiago Delgado Campo | Completa |
| 2. Replicación: Esclavos + Verificación | Eddie Santiago Delgado Campo | Completa |
| 3 a 6 | ... | Pendiente |
