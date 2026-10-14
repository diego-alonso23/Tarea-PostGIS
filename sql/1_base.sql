-- Etapa 1: extensión, esquemas, bitácora (etl_log) y zona
-- Variables psql: :lonmin :latmin :lonmax :latmax :pbf :gtfs :comunas

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS hstore;   -- other_tags de OSM se carga como hstore
DROP SCHEMA IF EXISTS osm_raw  CASCADE;
DROP SCHEMA IF EXISTS gtfs_raw CASCADE;
CREATE SCHEMA osm_raw;
CREATE SCHEMA gtfs_raw;

DROP TABLE IF EXISTS etl_log;
CREATE TABLE etl_log (id serial PRIMARY KEY, ts timestamptz DEFAULT now(),
                      paso text, detalle text, n bigint);
INSERT INTO etl_log(paso, detalle) VALUES
  ('fuente_osm',   :'pbf'), ('fuente_gtfs', :'gtfs'), ('fuente_dpa', :'comunas');

-- Caja de la zona, en 5361, para mapas y recortes
DROP TABLE IF EXISTS zona CASCADE;
CREATE TABLE zona AS
SELECT 'santiago-centro'::text AS nombre,
       format('lon %s..%s, lat %s..%s', :lonmin, :lonmax, :latmin, :latmax) AS caja_lonlat,
       ST_Transform(ST_MakeEnvelope(:lonmin, :latmin, :lonmax, :latmax, 4326), 5361)
         ::geometry(Polygon, 5361) AS geom;

-- Se recarga comunas_cl desde comunas_cl.sql en cada corrida
DROP TABLE IF EXISTS public.comunas_cl CASCADE;
