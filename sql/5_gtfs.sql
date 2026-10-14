-- Etapa 5: COPY del GTFS y construcción de geometrías
-- paraderos_gtfs, recorridos (una LineString por shape_id), viajes_por_paradero

\copy gtfs_raw.stops      FROM '/tmp/etl/gtfs/stops.txt'      WITH (FORMAT csv, HEADER true)
\copy gtfs_raw.routes     FROM '/tmp/etl/gtfs/routes.txt'     WITH (FORMAT csv, HEADER true)
\copy gtfs_raw.trips      FROM '/tmp/etl/gtfs/trips.txt'      WITH (FORMAT csv, HEADER true)
\copy gtfs_raw.shapes     FROM '/tmp/etl/gtfs/shapes.txt'     WITH (FORMAT csv, HEADER true)
\copy gtfs_raw.stop_times FROM '/tmp/etl/gtfs/stop_times.txt' WITH (FORMAT csv, HEADER true)
\copy gtfs_raw.feed_info  FROM '/tmp/etl/gtfs/feed_info.txt'  WITH (FORMAT csv, HEADER true)

INSERT INTO etl_log(paso, detalle, n) VALUES
 ('gtfs_raw','stops.txt',      (SELECT count(*) FROM gtfs_raw.stops)),
 ('gtfs_raw','routes.txt',     (SELECT count(*) FROM gtfs_raw.routes)),
 ('gtfs_raw','trips.txt',      (SELECT count(*) FROM gtfs_raw.trips)),
 ('gtfs_raw','shapes.txt',     (SELECT count(*) FROM gtfs_raw.shapes)),
 ('gtfs_raw','stop_times.txt (cargado con \copy)', (SELECT count(*) FROM gtfs_raw.stop_times));
INSERT INTO etl_log(paso, detalle)
SELECT 'fuente_gtfs_feed', format('feed_version=%s vigencia %s..%s',
                                  feed_version, feed_start_date, feed_end_date)
FROM gtfs_raw.feed_info;

-- ---- paraderos_gtfs: puntos 4326 -> 5361, recortados a la caja EN la base --
DROP TABLE IF EXISTS paraderos_gtfs CASCADE;
CREATE TABLE paraderos_gtfs AS
SELECT stop_id, stop_code, stop_name, location_type, parent_station, wheelchair_boarding,
       ST_Transform(ST_SetSRID(ST_MakePoint(stop_lon, stop_lat), 4326), 5361)
         ::geometry(Point, 5361) AS geom
FROM gtfs_raw.stops
WHERE stop_lon IS NOT NULL AND stop_lat IS NOT NULL
  AND stop_lon BETWEEN :lonmin AND :lonmax
  AND stop_lat BETWEEN :latmin AND :latmax;
ALTER TABLE paraderos_gtfs ADD PRIMARY KEY (stop_id);
INSERT INTO etl_log(paso, detalle, n)
SELECT 'gtfs_clip', 'stops fuera de la caja (descartados)',
       (SELECT count(*) FROM gtfs_raw.stops) - (SELECT count(*) FROM paraderos_gtfs);

-- ---- shape -> ruta ----------------------------------------------------------
-- Decisión: UNA fila por shape_id (ida/vuelta/variantes quedan separadas).
-- La ruta se toma de trips; si un shape lo usan varias rutas se deja la menor
-- route_id y se registra cuántos casos hubo.
CREATE TABLE gtfs_raw.shape_ruta AS
SELECT shape_id,
       min(route_id)                  AS route_id,
       count(DISTINCT route_id)       AS n_rutas,
       min(direction_id)              AS direction_id,
       count(*)                       AS n_viajes
FROM gtfs_raw.trips
WHERE shape_id IS NOT NULL
GROUP BY shape_id;
INSERT INTO etl_log(paso, detalle, n)
SELECT 'gtfs_shapes', 'shape_id usados por mas de una ruta', count(*)
FROM gtfs_raw.shape_ruta WHERE n_rutas > 1;

-- ---- recorridos: LineString por shape_id, vertices ordenados por secuencia --
DROP TABLE IF EXISTS recorridos CASCADE;
CREATE TABLE recorridos AS
WITH l AS (
  SELECT shape_id,
         ST_SetSRID(ST_MakeLine(ST_MakePoint(shape_pt_lon, shape_pt_lat)
                                ORDER BY shape_pt_sequence), 4326) AS g,
         count(*) AS n_pts
  FROM gtfs_raw.shapes
  GROUP BY shape_id
  HAVING count(*) >= 2
)
SELECT l.shape_id, sr.route_id, r.route_short_name, r.route_long_name, r.route_type,
       sr.direction_id, sr.n_viajes, l.n_pts,
       ST_Transform(l.g, 5361)::geometry(LineString, 5361) AS geom
FROM l
JOIN gtfs_raw.shape_ruta sr USING (shape_id)
JOIN gtfs_raw.routes r ON r.route_id = sr.route_id
WHERE ST_Intersects(l.g, ST_MakeEnvelope(:lonmin, :latmin, :lonmax, :latmax, 4326));
ALTER TABLE recorridos ADD PRIMARY KEY (shape_id);
INSERT INTO etl_log(paso, detalle, n) VALUES
 ('gtfs_shapes','shape_id distintos en shapes.txt', (SELECT count(DISTINCT shape_id) FROM gtfs_raw.shapes)),
 ('gtfs_shapes','shape_id sin ningun viaje en trips.txt (excluidos)',
    (SELECT count(DISTINCT shape_id) FROM gtfs_raw.shapes s
      WHERE NOT EXISTS (SELECT 1 FROM gtfs_raw.shape_ruta r WHERE r.shape_id = s.shape_id))),
 ('gtfs_shapes','shapes que cruzan la caja y quedan en recorridos', (SELECT count(*) FROM recorridos)),
 ('gtfs_shapes','recorridos de largo 0 (degenerados)', (SELECT count(*) FROM recorridos WHERE ST_Length(geom) = 0));

-- ---- (opcional del enunciado) viajes por paradero, desde stop_times --------
DROP TABLE IF EXISTS viajes_por_paradero CASCADE;
CREATE TABLE viajes_por_paradero AS
SELECT st.stop_id, count(*) AS n_paradas, count(DISTINCT st.trip_id) AS n_viajes
FROM gtfs_raw.stop_times st
JOIN paraderos_gtfs p USING (stop_id)
GROUP BY st.stop_id;
ALTER TABLE viajes_por_paradero ADD PRIMARY KEY (stop_id);
