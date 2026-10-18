-- Etapa 9: conteos, planes de ejecución, efecto de ST_Subdivide y uso de índices.
-- Se corre DESPUÉS de sql/7_consultas.sql:
--   docker compose exec -T db psql -U postgres -X -f /sql/9_planes.sql > resultados/planes_y_estado.txt
-- (pegar los planes relevantes en el README; idx_scan es acumulado, por eso la sección 4 va al final)
\timing on
\pset pager off

\echo '=== 1. Conteos exactos ==='
SELECT 'amenidades' t, count(*) FROM amenidades UNION ALL SELECT 'calles', count(*) FROM calles
UNION ALL SELECT 'comunas_cl', count(*) FROM comunas_cl UNION ALL SELECT 'comunas_sub', count(*) FROM comunas_sub
UNION ALL SELECT 'edificios', count(*) FROM edificios UNION ALL SELECT 'paraderos_gtfs', count(*) FROM paraderos_gtfs
UNION ALL SELECT 'paraderos_osm', count(*) FROM paraderos_osm UNION ALL SELECT 'recorridos', count(*) FROM recorridos
UNION ALL SELECT 'viajes_por_paradero', count(*) FROM viajes_por_paradero UNION ALL SELECT 'mv_grilla', count(*) FROM mv_grilla
ORDER BY 1;

\echo '=== 2. Planes con índice (P3, P5, P6) ==='
\echo '--- P3 (GTFS sin bus stop OSM a 50 m): anti-join, GIST de paraderos_osm del lado interno'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM paraderos_gtfs g
WHERE (g.location_type IS NULL OR g.location_type IN ('', '0'))
  AND NOT EXISTS (SELECT 1 FROM paraderos_osm o WHERE ST_DWithin(g.geom, o.geom, 50));

\echo '--- P5 (KNN ruta 210): CROSS JOIN LATERAL + <->, GIST de amenidades'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM (
  SELECT DISTINCT p.stop_id, p.geom FROM paraderos_gtfs p
  JOIN gtfs_raw.stop_times st ON st.stop_id = p.stop_id
  JOIN gtfs_raw.trips t ON t.trip_id = st.trip_id
  JOIN gtfs_raw.routes r ON r.route_id = t.route_id
  WHERE r.route_short_name = '210') pr
CROSS JOIN LATERAL (SELECT a.id FROM amenidades a
                    WHERE a.amenity IN ('pharmacy','hospital','clinic','doctors')
                    ORDER BY pr.geom <-> a.geom LIMIT 1) s;

\echo '--- P6 (edificios por celda): GIST de edificios.geom_pt del lado interno'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM mv_grilla c JOIN edificios e ON ST_Intersects(c.geom, e.geom_pt);

\echo '=== 3. Lo mismo SIN índice espacial (qué pasaría sin él) ==='
BEGIN;
SET LOCAL enable_indexscan = off; SET LOCAL enable_bitmapscan = off; SET LOCAL enable_indexonlyscan = off;
\echo '--- P3 sin índice'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM paraderos_gtfs g
WHERE (g.location_type IS NULL OR g.location_type IN ('', '0'))
  AND NOT EXISTS (SELECT 1 FROM paraderos_osm o WHERE ST_DWithin(g.geom, o.geom, 50));
\echo '--- P6 sin índice'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM mv_grilla c JOIN edificios e ON ST_Intersects(c.geom, e.geom_pt);
ROLLBACK;

\echo '=== 4. P4: efecto de ST_Subdivide en el tiempo (la suma de km debe coincidir) ==='
\echo '--- con comunas_cl (polígonos completos)'
SELECT round((sum(ST_Length(ST_Intersection(r.geom, c.geom))) / 1000)::numeric, 2) AS km
FROM comunas_cl c JOIN recorridos r ON ST_Intersects(r.geom, c.geom)
WHERE c.cut_com IN (SELECT DISTINCT cut_com FROM comunas_sub);
\echo '--- con comunas_sub (ST_Subdivide 256 vértices)'
SELECT round((sum(ST_Length(ST_Intersection(r.geom, cs.geom))) / 1000)::numeric, 2) AS km
FROM comunas_sub cs JOIN recorridos r ON ST_Intersects(r.geom, cs.geom);

\echo '=== 5. Uso de índices (correr al final) ==='
SELECT relname AS tabla, indexrelname AS indice, idx_scan AS usos,
       pg_size_pretty(pg_relation_size(indexrelid)) AS tamano
FROM pg_stat_user_indexes WHERE schemaname = 'public' ORDER BY idx_scan, relname;
