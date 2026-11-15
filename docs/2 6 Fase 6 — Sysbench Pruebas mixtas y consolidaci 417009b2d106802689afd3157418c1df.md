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

- **Misma máquina que la Fase 5**: PC con **12 núcleos y 32 GB de RAM**, Docker corriendo directamente sobre Linux (sin máquina virtual). Todos los contenedores (MySQL, NGINX y Sysbench) comparten esa CPU, RAM y disco, sin límites configurados. Carga media del equipo en reposo antes de empezar: ≈0,3.
- MySQL 8.0.46, NGINX 1.27, Sysbench 1.0.17.
- Dataset: tabla `sbtest.sbtest1` con 1.000.000 de filas, usuario `sbtest` (`mysql_native_password`), el mismo de la Fase 5.
- **Los valores de esta fase son directamente comparables con los de la Fase 5**: mismo equipo, mismo dataset y mismos parámetros (10 hilos, 60 s).
- Una versión anterior de esta fase se midió en otra máquina (8 núcleos, WSL2) y daba resultados muy dispares respecto a la Fase 5. Se **descartó por completo** y todas las pruebas se repitieron en el equipo de la Fase 5.

---

## Comandos ejecutados, en orden

### A. Preparación del entorno (Fases 1 a 5)

El entorno de la Fase 5 seguía creado (contenedores detenidos y volúmenes con los datos), así que no hubo que repetir la preparación.

```bash
docker compose up -d
./scripts/verify-replication.sh
for n in mysql-master mysql-slave1 mysql-slave2; do
  docker exec $n sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT COUNT(*) FROM sbtest.sbtest1"' 2>/dev/null
done
uptime
```

- `up -d`: reutiliza los contenedores y volúmenes existentes y espera a los health checks.
- `verify-replication.sh`: debe dar `RESULTADO: OK` en ambos esclavos (así fue).
- El `COUNT(*)` debe dar `1000000` en los tres nodos (así fue) y `uptime` confirma que la máquina está en reposo antes de medir.

Si se parte de una máquina nueva, la preparación completa (`.env`, usuario `replicador`, usuario `sbtest` y `prepare` del dataset) está en las Fases 1 a 5.

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

#### Lectura directa a cada nodo

No hizo falta un diagnóstico aparte: los escenarios A2 (directo al maestro) y A3 (directo a un esclavo) del script ya dan la línea base sin proxy. Ambos rinden prácticamente igual (≈7.300–7.500 TPS), así que MySQL rinde igual en cualquier nodo y la diferencia con A1 es el costo del salto por NGINX.

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

### Esta fase (10 hilos, 60 s, equipo de 12 núcleos, 0 errores en todas las pruebas)

Dos corridas completas del script en el mismo equipo. Se muestra el promedio de TPS y los valores de la corrida 2 para el resto; los logs de cada corrida están en `resultados/fase6-corrida1/` y `resultados/fase6/`.

| Esc. | Escenario | Hilos | TPS c1 | TPS c2 | TPS prom. | avg (ms) | p95 (ms) | max (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A1 | Lectura vía NGINX :3308 (2 esclavos) | 10 | 4.799 | 4.708 | 4.754 | 2,12 | 2,71 | 18,48 |
| A2 | Lectura directo al maestro (sin proxy) | 10 | 7.488 | 7.393 | 7.440 | 1,35 | 1,89 | 16,55 |
| A3 | Lectura directo a 1 esclavo (sin proxy) | 10 | 7.392 | 7.274 | 7.333 | 1,37 | 1,93 | 18,03 |
| B1 | Mixta `oltp_read_write` vía :3307 (todo al maestro) | 10 | 782 | 862 | 822 | 11,59 | 18,95 | 136,08 |
| B2 | Mixta dividida: lecturas vía :3308 | 8 | 3.044 | 2.939 | 2.991 | 2,72 | 4,10 | 64,36 |
| B2 | Mixta dividida: escrituras vía :3307 | 2 | 230 | 220 | 225 | 9,09 | 15,55 | 90,37 |
| C1 | Lectura vía NGINX con **slave1 caído** | 10 | 4.595 | 4.496 | 4.545 | 2,22 | 2,81 | 20,53 |
| C2 | Dividida con slave1 caído: lecturas | 8 | 2.928 | 2.619 | 2.774 | 3,05 | 5,28 | 61,91 |
| C2 | Dividida con slave1 caído: escrituras | 2 | 270 | 252 | 261 | 7,94 | 12,98 | 226,68 |

Las dos corridas difieren como máximo un 11 % en TPS (B1 y las lecturas de C2); en el resto, menos de un 7 %.

### Extras medidos en las mismas corridas

| Medición | Resultado |
| --- | --- |
| Retraso de replicación bajo escrituras (máx. `Seconds_Behind_Master`, muestreo cada 5 s) | 1 s en slave1 y 1 s en slave2, tanto en B2 como en C2, en ambas corridas |
| Puesta al día de slave1 al volver (GTID) | 0 s (corrida 1) y 1 s (corrida 2), tras ≈60 s de escrituras con slave1 caído |

### Fase 5 (solo lectura, mismo equipo de 12 núcleos)

| Hilos | Vía NGINX (2 esclavos) | Vía NGINX (1 esclavo) | Directo a 1 esclavo |
| --- | --- | --- | --- |
| 10 (60 s) | 5174 TPS · avg 1,93 ms · p95 2,52 ms | 4927 TPS · avg 2,03 ms · p95 2,76 ms | 8014 TPS · avg 1,25 ms · p95 1,82 ms |
| 64 (30 s) | 5136 TPS · avg 12,45 ms · p95 23,10 ms | 5358 TPS · avg 11,94 ms · p95 23,52 ms | 7791 TPS · avg 8,21 ms · p95 17,63 ms |
| 128 (30 s) | 4873 TPS · avg 26,25 ms · p95 48,34 ms | 4977 TPS · avg 25,70 ms · p95 53,85 ms | 7321 TPS · avg 17,47 ms · p95 39,65 ms |

### Coherencia entre Fase 5 y Fase 6 (10 hilos, solo lectura)

| | Fase 5 | Fase 6 (promedio de 2 corridas) | Diferencia |
| --- | --- | --- | --- |
| Directo a 1 esclavo | 8.014 TPS | 7.333 TPS | −8 % |
| Vía NGINX (2 esclavos) | 5.174 TPS | 4.754 TPS | −8 % |
| Vía NGINX (1 esclavo) | 4.927 TPS | 4.545 TPS (C1, esclavo caído) | −8 % |
| Pérdida por pasar por NGINX | −35 % | −35 % | igual |

Las dos fases coinciden: ≈8 % menos de TPS en la Fase 6 (variación normal de una corrida a otra, otro momento y otras condiciones del equipo) y exactamente la misma proporción de costo del proxy.

---

## Conclusiones

1. **El balanceo no mejoró el throughput en este entorno; lo redujo.** Vía NGINX se obtuvo ≈4.750 TPS frente a ≈7.330 directo a un nodo (−35 %, igual que en la Fase 5). Maestro y esclavo rinden igual por separado, así que el cuello de botella no es MySQL sino el salto por el proxy, que además comparte CPU con los nodos.
2. **Dos esclavos rinden igual que uno.** A1 (2 esclavos, ≈4.750 TPS) y C1 (1 esclavo vivo, ≈4.545 TPS) son casi equivalentes, y en la Fase 5 también (5.174 y 4.927). Todos los contenedores comparten CPU, RAM y disco, así que un segundo esclavo reparte la capacidad existente en vez de añadir más. El balanceo de lectura aporta cuando cada esclavo corre en hardware distinto.
3. **Con un esclavo caído el rendimiento bajó muy poco** (C1 ≈ −4 % frente a A1; lecturas de C2 ≈ −7 % frente a B2, en el borde del ruido entre corridas). Lo que el balanceador sí garantiza es la **disponibilidad**: 0 errores en todas las pruebas, incluida la que tuvo `slave1` apagado. El costo real de una caída está en la latencia de detección (3 a 5 s para los primeros clientes, Fase 4), que estas medias no incluyen porque se hizo un calentamiento con el nodo ya apagado.
4. **Las escrituras de la prueba dividida fueron algo más rápidas con un esclavo menos** (≈225 → ≈261 TPS, +16 %). Es una diferencia mayor que la variabilidad entre corridas, pero no se aisló con una prueba adicional; la hipótesis es que hay menos replicación compitiendo por la CPU.
5. **Las escrituras son lo más caro y no escalan con el balanceo.** La mixta completa (B1) llega a ≈820 TPS con ≈12 ms de latencia media, frente a ≈7.300 de la lectura pura. Todas pasan por el único maestro, que además persiste el binlog en cada commit.
6. **Consistencia eventual presente pero pequeña.** Bajo escritura continua (2 hilos) los esclavos fueron como máximo 1 s por detrás del maestro. Una aplicación que lea justo después de escribir por el 3308 puede aun así no ver su propio cambio.
7. **La recuperación funciona sola.** Al volver, `slave1` se puso al día por GTID en 0 a 1 s, sin intervención manual.

### Limitaciones

- Una sola máquina y dos corridas por escenario; las diferencias menores a ≈11 % están dentro del ruido.
- Cliente (Sysbench), proxy y servidores comparten el mismo host.
- Un solo dataset de 1 tabla y 1.000.000 de filas, y una sola carga de 10 hilos (la Fase 5 sí probó 64 y 128).
- Con solo 2 hilos de escritura el retraso de replicación es pequeño; con más hilos de escritura sería mayor y no se midió.
- No se probó la caída del maestro ni un esclavo con la replicación rota (el health check de NGINX es solo TCP y lo seguiría considerando sano).
- La causa exacta del costo del proxy no se aisló: se midió el efecto, no se probó el mecanismo.

---

## Problemas comunes y solución

### 1. Ningún archivo del repo crea el usuario `replicador`

- **Síntoma:** en una máquina nueva, los esclavos no pueden replicar.
- **Causa:** el usuario se creó a mano en la Fase 1 y el README solo dice `docker compose up -d`.
- **Solución:** crearlo en el maestro con `CREATE USER` / `GRANT` (ver Fase 1/5). Se recomienda un script de inicialización del maestro (`mysql/master-init/`).

### 2. `oltp_read_write` no se puede repartir entre maestro y esclavos

- **Síntoma:** al querer medir "lectura/escritura mixta con balanceo", todo el tráfico del script iba al maestro.
- **Causa:** Sysbench usa una única conexión por hilo hacia un solo host, y NGINX trabaja en capa 4: no distingue `SELECT` de `INSERT`. Apuntar `oltp_read_write` al 3308 fallaría por `super_read_only`.
- **Solución:** medir dos configuraciones: la mixta contra el 3307 (B1) y la prueba dividida con dos Sysbench simultáneos, uno de lectura al 3308 y uno de escritura al 3307 (B2). Esta última representa mejor a una aplicación real.

### 3. Resultados dispares entre la Fase 5 y la Fase 6 (resuelto)

- **Síntoma:** la primera versión de la Fase 6 daba ≈770 TPS vía NGINX frente a ≈5.100 de la Fase 5, y un costo del proxy de −64 % frente a −35 %.
- **Causa:** la Fase 6 se había medido en otra máquina (8 núcleos, WSL2, 7,4 GB), no comparable con la de la Fase 5.
- **Solución:** descartar esos resultados y repetir toda la fase en la máquina de la Fase 5. Ahora ambas fases coinciden (ver "Coherencia entre Fase 5 y Fase 6").

### 4. Detalles que no son errores

- El mensaje `Using a password on the command line interface can be insecure` de `mysql` es solo un aviso; se descarta con `2>/dev/null`.
- Los escenarios con `slave1` caído pueden mostrar `slave1=caído` en `lag.csv`; es esperado, no una falla del muestreador.
- Si se repite una verificación de replicación justo después de una prueba de escritura, puede dar `FALLO` unos segundos hasta que los esclavos se pongan al día; por eso `benchmark-mixto.sh` espera a que los GTID coincidan entre escenarios.

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
- [x]  Pruebas adicionales: retraso de replicación, puesta al día de slave1 y lectura directa sin proxy (A2 y A3)
- [x]  Todas las métricas (Fase 5 y Fase 6) consolidadas en una tabla comparativa
- [x]  Conclusiones redactadas sobre qué configuración rindió mejor y por qué
- [x]  README actualizado con los resultados finales y cómo reproducir todas las pruebas