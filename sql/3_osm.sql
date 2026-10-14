-- Etapa 3: OSM (después de ogr2ogr a osm_raw)
-- calles, edificios (con punto interior), paraderos_osm, amenidades; cuenta reparaciones

-- ---- conteos crudos y geometrías inválidas (antes de reparar) -------------
INSERT INTO etl_log(paso, detalle, n) VALUES
 ('osm_raw','points',        (SELECT count(*) FROM osm_raw.points)),
 ('osm_raw','lines',         (SELECT count(*) FROM osm_raw.lines)),
 ('osm_raw','multipolygons', (SELECT count(*) FROM osm_raw.multipolygons));
INSERT INTO etl_log(paso, detalle, n)
SELECT 'osm_repair', 'multipolygons (todos) con geometria invalida', count(*)
FROM osm_raw.multipolygons WHERE geom IS NOT NULL AND NOT ST_IsValid(geom);
INSERT INTO etl_log(paso, detalle, n)
SELECT 'osm_repair', 'edificios con geometria invalida -> ST_MakeValid', count(*)
FROM osm_raw.multipolygons WHERE building IS NOT NULL AND geom IS NOT NULL AND NOT ST_IsValid(geom);

-- ---- calles ---------------------------------------------------------------
DROP TABLE IF EXISTS calles CASCADE;
CREATE TABLE calles AS
SELECT osm_id::text AS osm_id, name, highway, geom::geometry(LineString, 5361) AS geom
FROM osm_raw.lines
WHERE highway IS NOT NULL AND geom IS NOT NULL AND NOT ST_IsEmpty(geom);
ALTER TABLE calles ADD COLUMN id serial PRIMARY KEY;

-- ---- edificios (poligono reparado + punto interior) -----------------------
-- osm_id: relaciones en osm_id, vias cerradas en osm_way_id (jsonb evita
-- depender de que la columna exista con ese nombre exacto)
DROP TABLE IF EXISTS edificios CASCADE;
CREATE TABLE edificios AS
WITH r AS (
  SELECT COALESCE(m.osm_id, to_jsonb(m)->>'osm_way_id') AS osm_id,
         m.name, m.building, m.amenity,
         NOT ST_IsValid(m.geom) AS reparada,
         ST_Multi(ST_CollectionExtract(
           CASE WHEN ST_IsValid(m.geom) THEN m.geom ELSE ST_MakeValid(m.geom) END, 3)) AS geom
  FROM osm_raw.multipolygons m
  WHERE m.building IS NOT NULL AND m.geom IS NOT NULL
)
SELECT osm_id, name, building, amenity, reparada,
       geom::geometry(MultiPolygon, 5361)                         AS geom,
       ST_PointOnSurface(geom)::geometry(Point, 5361)             AS geom_pt,
       ST_Area(geom)                                              AS area_m2
FROM r
WHERE NOT ST_IsEmpty(geom);
ALTER TABLE edificios ADD COLUMN id serial PRIMARY KEY;
INSERT INTO etl_log(paso, detalle, n)
SELECT 'osm_repair', 'edificios descartados (irreparables: vacios o sin area tras ST_MakeValid)',
       (SELECT count(*) FROM osm_raw.multipolygons WHERE building IS NOT NULL AND geom IS NOT NULL)
       - (SELECT count(*) FROM edificios);
INSERT INTO etl_log(paso, detalle, n)
SELECT 'osm_repair', 'edificios reparados presentes en la tabla final', count(*)
FROM edificios WHERE reparada;

-- ---- paraderos_osm (highway = 'bus_stop') ---------------------------------
DROP TABLE IF EXISTS paraderos_osm CASCADE;
CREATE TABLE paraderos_osm AS
SELECT osm_id::text AS osm_id, name, ref, other_tags->'operator' AS operator,
       other_tags->'public_transport' AS public_transport, other_tags->'bus' AS bus,
       geom::geometry(Point, 5361) AS geom
FROM osm_raw.points
WHERE highway = 'bus_stop' AND geom IS NOT NULL;
ALTER TABLE paraderos_osm ADD COLUMN id serial PRIMARY KEY;

-- ---- amenidades (nodos + áreas representadas por su punto interior) -------
DROP TABLE IF EXISTS amenidades CASCADE;
CREATE TABLE amenidades AS
SELECT osm_id::text AS osm_id, name, other_tags->'amenity' AS amenity, 'nodo'::text AS origen,
       geom::geometry(Point, 5361) AS geom
FROM osm_raw.points
WHERE other_tags ? 'amenity' AND geom IS NOT NULL      -- en los nodos 'amenity' viene dentro de other_tags (hstore)
UNION ALL
SELECT COALESCE(m.osm_id, to_jsonb(m)->>'osm_way_id'), m.name, m.amenity, 'area',
       ST_PointOnSurface(ST_CollectionExtract(
         CASE WHEN ST_IsValid(m.geom) THEN m.geom ELSE ST_MakeValid(m.geom) END, 3))
         ::geometry(Point, 5361)
FROM osm_raw.multipolygons m
WHERE m.amenity IS NOT NULL AND m.geom IS NOT NULL;
DELETE FROM amenidades WHERE geom IS NULL OR ST_IsEmpty(geom);
ALTER TABLE amenidades ADD COLUMN id serial PRIMARY KEY;
