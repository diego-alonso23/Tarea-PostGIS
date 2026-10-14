#!/usr/bin/env bash
# cargar.sh — OSM + GTFS + DPA -> PostGIS en SRID 5361, con índices y ANALYZE.
# Uso:  ./cargar.sh [carpeta_con_fuentes]   (def. ./datos con *.pbf, GTFS*.zip, comunas_cl.sql)
# Opcionales: LON_MIN LAT_MIN LON_MAX LAT_MAX (caja), KEEP_RAW=1 (conserva osm_raw). SQL en sql/.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'    # Git Bash: no reescribir /datos/...
LON_MIN="${LON_MIN:--70.75}"; LAT_MIN="${LAT_MIN:--33.52}"; LON_MAX="${LON_MAX:--70.52}"; LAT_MAX="${LAT_MAX:--33.36}"
log() { printf '\n\033[1m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
die() { trap - ERR; printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
trap 'die "falló la línea $LINENO (comando: $BASH_COMMAND)"' ERR

# --- el repo debe traer sql/ (si no, Docker monta una carpeta vacía y falla más adelante)
for f in sql/1_base.sql sql/2_dpa.sql sql/3_osm.sql sql/4_gtfs_tablas.sql sql/5_gtfs.sql sql/6_indices.sql; do
  [[ -f "$f" ]] || die "falta $f en el repositorio (copia la carpeta sql/ junto a cargar.sh)"
done

# --- fuentes: se buscan por patrón en la carpeta (no hay rutas que editar)
DATOS_IN="${1:-${DATOS_DIR:-./datos}}"
[[ -d "$DATOS_IN" ]] || die "no existe la carpeta de fuentes: $DATOS_IN"
DATOS_ABS="$(cd "$DATOS_IN" && pwd)"
if [[ "$DATOS_ABS" == "$(pwd)/datos" ]]; then unset DATOS_DIR          # compose monta ./datos
else DATOS_DIR="$(cd "$DATOS_IN" && { pwd -W 2>/dev/null || pwd; })"; export DATOS_DIR; fi   # pwd -W: Git Bash
find_one() { local f; f="$(find "$DATOS_ABS/" -maxdepth 1 -type f -iname "$1" | sort | tail -n 1)"
             [[ -n "$f" ]] || die "falta en $DATOS_ABS un archivo '$1' ($2)"; basename "$f"; }
PBF="$(find_one '*.pbf' 'extracto OSM de Chile')"; GTFS="$(find_one 'gtfs*.zip' 'GTFS del DTPM')"
COMUNAS="$(find_one 'comunas_cl.sql' 'DPA, Lab 03')"
echo "Fuentes: $PBF | $GTFS | $COMUNAS   Zona: lon $LON_MIN..$LON_MAX, lat $LAT_MIN..$LAT_MAX"

# --- infraestructura: un solo contenedor (PostGIS + ogr2ogr); todo se ejecuta dentro de él
log "Levantando PostGIS"; docker compose up -d --build --wait
dexec()   { docker compose exec -T db "$@"; }
psql_db() { dexec env PGOPTIONS='-c client_min_messages=warning' psql -U postgres -X -q -v ON_ERROR_STOP=1 \
              -v lonmin="$LON_MIN" -v latmin="$LAT_MIN" -v lonmax="$LON_MAX" -v latmax="$LAT_MAX" \
              -v pbf="$PBF" -v gtfs="$GTFS" -v comunas="$COMUNAS" "$@"; }
etapa()   { log "$2"; psql_db -f "/sql/$1"; }
for f in "$PBF" "$GTFS" "$COMUNAS"; do
  dexec test -f "/datos/$f" || die "el contenedor no ve /datos/$f. En /datos hay: $(dexec ls /datos 2>&1 | tr '\n' ' ')"
done
dexec bash -c 'rm -rf /tmp/etl && mkdir -p /tmp/etl/gtfs'

etapa 1_base.sql "1/6 Base, zona y bitácora"
log "2/6 DPA: comunas_cl + ST_Subdivide"; psql_db -f "/datos/$COMUNAS" >/dev/null; psql_db -f /sql/2_dpa.sql

log "3/6 OSM: ogr2ogr (-spat a la caja, -> EPSG:5361) y tablas derivadas"
# Se lee el PBF de Chile entero con filtro espacial: ~200 MB de RAM (osmium extract -s smart pedía >3 GB)
TS="$(dexec osmium fileinfo -g header.option.osmosis_replication_timestamp "/datos/$PBF" 2>/dev/null || true)"
psql_db -c "INSERT INTO etl_log(paso, detalle) VALUES ('fuente_osm_fecha', '${TS:-no informada}')"
mkdir -p logs
dexec ogr2ogr --config OGR_INTERLEAVED_READING YES   -f PostgreSQL "PG:dbname=postgres user=postgres" "/datos/$PBF" points lines multipolygons \
  -spat "$LON_MIN" "$LAT_MIN" "$LON_MAX" "$LAT_MAX" -spat_srs EPSG:4326 -t_srs EPSG:5361 -overwrite -gt 65536 \
  -lco SCHEMA=osm_raw -lco GEOMETRY_NAME=geom -lco SPATIAL_INDEX=NONE -lco PRECISION=NO -lco COLUMN_TYPES=other_tags=hstore 2> logs/ogr2ogr.log
AVISOS="$(grep -c -E '^(Warning|ERROR)' logs/ogr2ogr.log || true)"
echo "ogr2ogr: $AVISOS avisos de GDAL por anillos degenerados de OSM (logs/ogr2ogr.log)"
psql_db -c "INSERT INTO etl_log(paso, detalle, n) VALUES ('osm_ogr2ogr', 'avisos de GDAL al ensamblar geometrias (logs/ogr2ogr.log)', ${AVISOS:-0})"
psql_db -f /sql/3_osm.sql

log "4/6 GTFS: descomprimir y validar cabeceras"
dexec bash -c 'unzip -oq "/datos/$1" -d /tmp/etl/gtfs && sed -i "1s/^\xEF\xBB\xBF//" /tmp/etl/gtfs/*.txt' _ "$GTFS"
psql_db -f /sql/4_gtfs_tablas.sql
for t in stops routes trips shapes stop_times feed_info; do      # COPY es posicional: columnas = cabecera
  esperada="$(psql_db -At -c "SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema='gtfs_raw' AND table_name='$t'")"
  obtenida="$(dexec head -n 1 "/tmp/etl/gtfs/$t.txt" | tr -d '\r')"
  [[ "$esperada" == "$obtenida" ]] || die "cabecera inesperada en $t.txt (¿cambió el GTFS?)"$'\n'"  esperada: $esperada"$'\n'"  obtenida: $obtenida"
done
etapa 5_gtfs.sql "5/6 GTFS: COPY + paraderos_gtfs, recorridos, viajes_por_paradero"

etapa 6_indices.sql "6/6 Índices y ANALYZE"
[[ "${KEEP_RAW:-0}" == 1 ]] || psql_db -c "DROP SCHEMA osm_raw CASCADE"
dexec rm -rf /tmp/etl; psql_db -c "ANALYZE"
log "Listo. Comprueba con ./verificar.sh  (desde el host: localhost:5433, base postgres, clave postgres)"
