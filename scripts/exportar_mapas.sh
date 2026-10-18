#!/usr/bin/env bash
# exportar_mapas.sh — corre las consultas de los mapas y exporta resultados/mapas.gpkg
# (capas: grilla, comunas_densidad, paraderos, fuentes). Luego dibuja los PNG con scripts/mapas.py.
# Uso:  ./scripts/exportar_mapas.sh        (después de ./cargar.sh)
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # raíz del repo
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
die() { trap - ERR; printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
trap 'die "falló la línea $LINENO (comando: $BASH_COMMAND)"' ERR

docker compose up -d --wait >/dev/null
dexec() { docker compose exec -T db "$@"; }
mkdir -p resultados

echo "Consultas que alimentan los mapas (Q1 densidad por comuna, Q6 grilla hexagonal)..."
dexec env PGOPTIONS='-c client_min_messages=warning' psql -U postgres -X -q -v ON_ERROR_STOP=1 -P pager=off -f /sql/8_mapas.sql

echo "Exportando resultados/mapas.gpkg ..."
dexec rm -f /salidas/mapas.gpkg
UPD=""   # la primera capa crea el archivo; las siguientes se agregan con -update
export_layer() {   # nombre  consulta  [opciones extra de ogr2ogr]
  dexec ogr2ogr -f GPKG $UPD /salidas/mapas.gpkg "PG:dbname=postgres user=postgres" \
    -sql "$2" -nln "$1" "${@:3}"
  UPD="-update"
}
export_layer grilla "SELECT id, n_edificios, n_recorridos, interior, rank_top, geom FROM mv_grilla" -a_srs EPSG:5361
export_layer comunas_densidad "SELECT cut_com, comuna, area_comuna_km2, area_zona_km2, pct_comuna_en_zona, n_paraderos, paraderos_km2, geom FROM mv_q1_densidad" -a_srs EPSG:5361
export_layer paraderos "SELECT stop_id, stop_name, geom FROM paraderos_gtfs WHERE location_type IS NULL OR location_type IN ('', '0')" -a_srs EPSG:5361
export_layer fuentes "SELECT paso, detalle FROM etl_log WHERE paso LIKE 'fuente%' ORDER BY id"   # tabla sin geometría
echo "OK: resultados/mapas.gpkg"

PY="$(command -v python3 || command -v python || true)"
if [[ -n "$PY" ]] && "$PY" -c 'import geopandas, matplotlib' 2>/dev/null; then
  "$PY" scripts/mapas.py
else
  echo "Para los PNG: pip install geopandas matplotlib && python scripts/mapas.py   (o abre resultados/mapas.gpkg en QGIS)"
fi
