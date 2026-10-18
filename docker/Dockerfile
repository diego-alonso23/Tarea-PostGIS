# PostgreSQL 16 + PostGIS + GDAL (ogr2ogr) en una sola imagen, sobre Debian bookworm.
# (postgis/postgis:16-3.4 es bullseye y su repo apt ya no existe: apt-get update falla.)
FROM postgres:16-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends gdal-bin postgresql-16-postgis-3 unzip ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# osmium solo se usa para leer la fecha del extracto OSM; si faltara, cargar.sh sigue sin ella
RUN apt-get update && (apt-get install -y --no-install-recommends osmium-tool || true) \
 && rm -rf /var/lib/apt/lists/*
