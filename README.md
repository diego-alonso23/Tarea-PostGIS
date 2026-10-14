# Tarea 1 — PostGIS de punta a punta: Santiago centro

Procesamiento Masivo de Datos (ELE051-B / EIN102B · USM 2026-2) · Profesor: Diego Ramírez · Paralelo 701

**Integrantes:** Diego Peña - Benjamín Tello
**Repositorio:** https://github.com/diego-alonso23/Tarea-PostGIS.git

Pipeline geoespacial completo (fuente → carga → índices → transformación → consultas) que cruza
**OpenStreetMap** con el **GTFS del transporte público de Santiago (DTPM)** y la **División Política
Administrativa (comunas)**, todo en PostGIS y en **SRID 5361** (SIRGAS-Chile / UTM 19S).

> Estado de este repositorio: Partes A (infraestructura) y B (ETL) completas. Parte C (consultas) e
> informe: COMPLETAR (pendiente).

## Estructura

```
├── docker-compose.yml   un servicio: PostGIS + ogr2ogr; monta datos/, sql/ y salidas/
├── Dockerfile           postgres:16-bookworm + postgis + gdal-bin
├── cargar.sh            orquesta la carga: fuentes -> tablas creadas, indexadas y con ANALYZE
├── sql/                 el SQL de cada etapa (1_base, 2_dpa, 3_osm, 4_gtfs_tablas, 5_gtfs, 6_indices)
├── verificar.sh         comprueba la base y actualiza el estado de este README
├── verificar_repo.sh    revisa el repo antes de subirlo (datos, permisos, README)
├── datos/               fuentes descargadas a mano (NO se versionan)
└── salidas/             exportaciones (GeoPackage de mapas, estado_carga.md) — SÍ se versionan
```

## Requisitos

Docker (Docker Desktop en Windows/macOS) con `docker compose` v2, y un shell bash
(Linux, macOS o **Git Bash** en Windows). ~6 GB libres en disco y ~4 GB de RAM para Docker.

## Cómo reproducir desde cero

1. Clonar el repositorio y crear la carpeta de datos:
   ```bash
   git clone <URL-del-repo> && cd <repo>
   mkdir -p datos
   ```
2. Descargar las tres fuentes y dejarlas **tal cual** en `./datos/`:

   | Archivo en `datos/` | De dónde |
   |---|---|
   | `*.pbf` (extracto de Chile, p. ej. `chile-261002.osm.pbf`) | <https://download.geofabrik.de/south-america/chile-latest.osm.pbf> |
   | `GTFS_*.zip` (GTFS vigente) | <https://www.dtpm.cl/index.php/noticias/gtfs-vigente> |
   | `comunas_cl.sql` (DPA 2023, Laboratorio 03) | repositorio del curso: `03/datos/comunas_cl.sql` |

   El script detecta los archivos por patrón (`*.pbf`, `gtfs*.zip`, `comunas_cl.sql`); no hay que editar rutas.
3. Levantar la infraestructura (la primera vez construye la imagen, ~1–2 min):
   ```bash
   docker compose up -d --build
   ```
4. Cargar todo (~1–2 min):
   ```bash
   ./cargar.sh
   ```
5. Verificar (opcional, recomendado) y regenerar el estado de abajo:
   ```bash
   ./verificar.sh
   ```

Es idempotente: `./cargar.sh` se puede repetir y rehace todo desde cero. Se puede cambiar la caja
con `LON_MIN LAT_MIN LON_MAX LAT_MAX`, o dar otra carpeta: `./cargar.sh /ruta/a/fuentes`.
Conexión desde el host (QGIS, psql): `localhost:5433`, base `postgres`, usuario/clave `postgres`.
Para empezar de cero también con el volumen: `docker compose down -v`.

## Fuentes y versiones

| Fuente | Versión usada |
|---|---|
| OpenStreetMap — extracto de Chile (Geofabrik) | `chile-261002` · marca de tiempo del extracto 2026-10-02T20:21:34Z · licencia ODbL |
| GTFS vigente DTPM | `GTFS_20261003.zip` (versión y vigencia exactas en el estado, más abajo) |
| DPA 2023 — comunas | `comunas_cl.sql` (Laboratorio 03), 345 comunas |
| Zona `santiago-centro` | caja lon −70,75…−70,52 · lat −33,52…−33,36 (parámetros de `cargar.sh`) |

## Decisiones técnicas

- **SRID 5361** para todo. OSM y GTFS vienen en 4326 y se transforman al cargar; `comunas_cl` ya viene en 5361.
  `verificar.sh` comprueba el SRID de cada columna geométrica.
- **Carga de OSM: `ogr2ogr` con filtro espacial `-spat`** directo sobre el PBF de Chile, con `other_tags` como
  `hstore` (de ahí se saca `amenity` de los nodos). Es el equivalente justificado del `preparar_datos.py` del
  Lab 05: tarda ~15 s y usa ~200 MB de RAM. Los objetos que cruzan el borde de la caja quedan **completos**
  (no recortados).
- **Reparación de geometrías:** los polígonos inválidos de OSM se reparan con `ST_MakeValid` +
  `ST_CollectionExtract(…, 3)`. Los que quedan vacíos o sin área se descartan. Los conteos (inválidos,
  reparados, descartados) salen de `etl_log` y están en el estado de abajo (filas `osm_repair`).
  GDAL además avisa de anillos degenerados de OSM al ensamblar (`logs/ogr2ogr.log`, conteo en `osm_ogr2ogr`).
- **Edificios: polígono *y* punto interior.** Se conserva `geom` (MultiPolygon, para áreas e intersecciones) y se
  agrega `geom_pt = ST_PointOnSurface(geom)`, que a diferencia del centroide siempre cae dentro del edificio
  y permite joins punto-en-polígono y `ST_DWithin` baratos. Ambos con índice GIST.
- **Amenidades:** nodos con `amenity` más áreas con `amenity` representadas por su punto interior (columna `origen`).
- **`paraderos_osm`:** `highway = 'bus_stop'`.
- **`paraderos_gtfs`:** `stops.txt` → `ST_Transform(ST_SetSRID(ST_MakePoint(lon, lat), 4326), 5361)`, recortado a la
  caja **en la base** (filtro por lon/lat). Se conserva `location_type`: incluye paraderos (vacío o `0`),
  estaciones (`1`) y accesos de metro (`2`). Las consultas filtran `location_type IS NULL OR location_type = '0'`
  para no contar dos veces una misma estación.
- **`recorridos`:** `shapes.txt` se carga con `COPY` a una tabla cruda (`gtfs_raw.shapes`) y la línea se construye en
  SQL: `ST_MakeLine(punto ORDER BY shape_pt_sequence)`. **Una fila por `shape_id`**: ida, vuelta y variantes de una
  misma ruta quedan como filas distintas (con `route_short_name` y `direction_id` para agruparlas). La ruta se
  asocia vía `trips.txt → routes.txt`; si un shape lo usaran varias rutas se toma la de menor `route_id` y se
  registra cuántos casos hubo. Se descartan shapes con < 2 puntos y los que ningún viaje usa; los que cruzan la
  caja se guardan completos. `verificar.sh` comprueba que primer y último vértice coinciden con la secuencia mínima y máxima.
- **`stop_times.txt`:** cargado con `\copy` (no INSERT fila por fila) a `gtfs_raw.stop_times`; de ahí sale
  `viajes_por_paradero`. El número de filas está en el estado.
- **DPA:** `comunas_cl` tal cual el Lab 03 (con su GIST). Además `comunas_sub`: `ST_Subdivide(…, 256)` solo de las
  comunas que tocan la caja, para los joins pesados.
- **Comunas parciales:** la caja corta varias comunas (solo asoman por el borde). Para densidades y kilómetros por
  comuna se usa el área/recorrido **recortado a la caja** (`zona`), no la comuna completa.

## Tablas, conteos e índices

<!-- ESTADO:BEGIN -->
_Generado por `verificar.sh` el 2026-10-14 22:26 UTC._

**Fuentes**

| Fuente | Detalle |
|---|---|
| fuente_osm | chile-261002_osm.pbf |
| fuente_gtfs | GTFS_20261003.zip |
| fuente_dpa | comunas_cl.sql |
| fuente_osm_fecha | 2026-10-02T20:21:34Z |
| fuente_gtfs_feed | feed_version=V168.20261003 vigencia 20261003..20261231 |

**Tablas y conteos** (SRID 5361 en todas las geometrías)

| Tabla | Filas |
|---|---:|
| public.amenidades | 20847 |
| public.calles | 100826 |
| public.comunas_cl | 345 |
| public.comunas_sub | 86 |
| public.edificios | 118778 |
| public.paraderos_gtfs | 7162 |
| public.paraderos_osm | 6568 |
| public.recorridos | 708 |
| public.viajes_por_paradero | 6811 |
| public.zona | 1 |
| gtfs_raw.feed_info | 1 |
| gtfs_raw.routes | 428 |
| gtfs_raw.shape_ruta | 859 |
| gtfs_raw.shapes | 456573 |
| gtfs_raw.stop_times | 1098529 |
| gtfs_raw.stops | 18455 |
| gtfs_raw.trips | 26159 |

**Índices** (`usos` = idx_scan acumulado; se revisa de nuevo al terminar la Parte C)

| Tabla | Índice | Tipo / columna | usos |
|---|---|---|---:|
| amenidades | amenidades_pkey | btree (id) | 0 |
| amenidades | idx_amenidades_amenity | btree (amenity) | 2 |
| amenidades | idx_amenidades_geom | gist (geom) | 0 |
| calles | calles_pkey | btree (id) | 0 |
| calles | idx_calles_geom | gist (geom) | 0 |
| calles | idx_calles_highway | btree (highway) | 2 |
| comunas_cl | comunas_cl_geom_idx | gist (geom) | 1 |
| comunas_cl | comunas_cl_pkey | btree (gid) | 0 |
| comunas_sub | idx_comunas_sub_geom | gist (geom) | 0 |
| edificios | edificios_pkey | btree (id) | 2 |
| edificios | idx_edificios_geom | gist (geom) | 0 |
| edificios | idx_edificios_geom_pt | gist (geom_pt) | 0 |
| paraderos_gtfs | idx_paraderos_gtfs_geom | gist (geom) | 0 |
| paraderos_gtfs | paraderos_gtfs_pkey | btree (stop_id) | 0 |
| paraderos_osm | idx_paraderos_osm_geom | gist (geom) | 0 |
| paraderos_osm | paraderos_osm_pkey | btree (id) | 2 |
| recorridos | idx_recorridos_geom | gist (geom) | 0 |
| recorridos | idx_recorridos_ruta | btree (route_short_name) | 0 |
| recorridos | recorridos_pkey | btree (shape_id) | 1 |
| viajes_por_paradero | viajes_por_paradero_pkey | btree (stop_id) | 0 |
| zona | idx_zona_geom | gist (geom) | 0 |

**Bitácora de la carga** (reparaciones, descartes, conteos crudos)

| Paso | Detalle | N |
|---|---|---:|
| dpa | comunas totales en comunas_cl | 345 |
| dpa | comunas con geometria invalida (se reparan solo en comunas_sub) | 0 |
| osm_ogr2ogr | avisos de GDAL al ensamblar geometrias (logs/ogr2ogr.log) | 86 |
| osm_raw | points | 254955 |
| osm_raw | lines | 169689 |
| osm_raw | multipolygons | 146675 |
| osm_repair | multipolygons (todos) con geometria invalida | 291 |
| osm_repair | edificios con geometria invalida -> ST_MakeValid | 181 |
| osm_repair | edificios descartados (irreparables: vacios o sin area tras ST_MakeValid) | 155 |
| osm_repair | edificios reparados presentes en la tabla final | 26 |
| gtfs_raw | stops.txt | 18455 |
| gtfs_raw | routes.txt | 428 |
| gtfs_raw | trips.txt | 26159 |
| gtfs_raw | shapes.txt | 456573 |
| gtfs_raw | stop_times.txt (cargado con \copy) | 1098529 |
| gtfs_clip | stops fuera de la caja (descartados) | 11293 |
| gtfs_shapes | shape_id usados por mas de una ruta | 0 |
| gtfs_shapes | shape_id distintos en shapes.txt | 981 |
| gtfs_shapes | shape_id sin ningun viaje en trips.txt (excluidos) | 122 |
| gtfs_shapes | shapes que cruzan la caja y quedan en recorridos | 708 |
| gtfs_shapes | recorridos de largo 0 (degenerados) | 0 |
<!-- ESTADO:END -->

### Índices que resultaron inútiles

COMPLETAR tras la Parte C: listar los índices con `idx_scan = 0` en `pg_stat_user_indexes` y explicar por qué.

## Qué no funcionó

- **`osmium extract -s smart` / `complete_ways`** sobre el PBF de Chile pedía > 3 GB de RAM y el proceso moría
  por falta de memoria. Se reemplazó por `ogr2ogr -spat` (arriba).
- **`apt-get` dentro de la imagen `postgis/postgis:16-3.4`**: esa imagen es Debian *bullseye* y su repositorio
  `apt.postgresql.org … bullseye-pgdg` ya no existe (404), así que `apt-get update` fallaba. Se construye
  sobre `postgres:16-bookworm` (instalando `postgresql-16-postgis-3` y `gdal-bin`), que sí tiene repositorio.
- **Git Bash en Windows** reescribe argumentos que empiezan con `/` (p. ej. `/datos/...` →
  `C:/Program Files/Git/datos/...`). `cargar.sh` desactiva esa conversión (`MSYS_NO_PATHCONV`).
- **Cabeceras del GTFS:** `COPY` no mapea por nombre de columna; si el GTFS cambia de columnas, `cargar.sh`
  se detiene con un mensaje claro en vez de cargar datos desordenados.

## Consultas (Parte C)

COMPLETAR (pendiente): archivos `.sql`, resultados, planes `EXPLAIN ANALYZE` y mapas.

