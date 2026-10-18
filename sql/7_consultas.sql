-- =========================================================================
-- PARTE C: CONSULTAS ESPACIALES (Santiago Centro)
-- Archivo: sql/7_consultas.sql
-- =========================================================================

\echo '--- Ejecutando P1: Paraderos por comuna y densidad ---'
WITH comunas_recortadas AS (
    SELECT 
        c.comuna,
        ST_Intersection(c.geom, z.geom) AS geom_util,
        ST_Area(ST_Intersection(c.geom, z.geom)) / 1e6 AS area_km2
    FROM public.comunas_cl c
    JOIN public.zona z ON ST_Intersects(c.geom, z.geom)
)
SELECT 
    cr.comuna AS nom_comuna,
    COUNT(p.stop_id) AS total_paraderos,
    ROUND(cr.area_km2::numeric, 2) AS area_zona_km2,
    ROUND((COUNT(p.stop_id) / NULLIF(cr.area_km2, 0))::numeric, 2) AS densidad_paraderos_km2
FROM comunas_recortadas cr
LEFT JOIN public.paraderos_gtfs p 
    ON ST_Contains(cr.geom_util, p.geom)
    AND (p.location_type IS NULL OR p.location_type = '0' OR p.location_type = '')
GROUP BY cr.comuna, cr.area_km2
HAVING COUNT(p.stop_id) > 0
ORDER BY densidad_paraderos_km2 DESC;


\echo '--- Ejecutando P2: Cobertura de edificios a > 500m (GTFS vs OSM) ---'
WITH edif_comuna AS (
    SELECT DISTINCT ON (e.id)
        e.id,
        e.geom_pt,
        cs.comuna
    FROM public.edificios e
    JOIN public.comunas_sub cs ON ST_Intersects(e.geom_pt, cs.geom)
)
SELECT 
    ec.comuna AS nom_comuna,
    COUNT(*) AS total_edificios,
    COUNT(*) FILTER (
        WHERE NOT EXISTS (
            SELECT 1 FROM public.paraderos_gtfs pg 
            WHERE (pg.location_type IS NULL OR pg.location_type = '0' OR pg.location_type = '')
              AND ST_DWithin(ec.geom_pt, pg.geom, 500)
        )
    ) AS sin_gtfs_500m,
    ROUND(100.0 * COUNT(*) FILTER (
        WHERE NOT EXISTS (
            SELECT 1 FROM public.paraderos_gtfs pg 
            WHERE (pg.location_type IS NULL OR pg.location_type = '0' OR pg.location_type = '')
              AND ST_DWithin(ec.geom_pt, pg.geom, 500)
        )
    ) / COUNT(*), 2) AS pct_sin_gtfs,
    COUNT(*) FILTER (
        WHERE NOT EXISTS (
            SELECT 1 FROM public.paraderos_osm po 
            WHERE ST_DWithin(ec.geom_pt, po.geom, 500)
        )
    ) AS sin_osm_500m,
    ROUND(100.0 * COUNT(*) FILTER (
        WHERE NOT EXISTS (
            SELECT 1 FROM public.paraderos_osm po 
            WHERE ST_DWithin(ec.geom_pt, po.geom, 500)
        )
    ) / COUNT(*), 2) AS pct_sin_osm
FROM edif_comuna ec
GROUP BY ec.comuna
ORDER BY total_edificios DESC;


\echo '--- Ejecutando P3: Dos fuentes, un objeto (Anti-join bidireccional a 50m) ---'
WITH gtfs_stops AS (
    SELECT stop_id, geom 
    FROM public.paraderos_gtfs 
    WHERE location_type IS NULL OR location_type = '0' OR location_type = ''
)
SELECT 
    (SELECT COUNT(*) FROM gtfs_stops) AS total_gtfs,
    (SELECT COUNT(*) FROM gtfs_stops g 
     WHERE NOT EXISTS (
         SELECT 1 FROM public.paraderos_osm o WHERE ST_DWithin(g.geom, o.geom, 50)
     )) AS gtfs_sin_osm_50m,
    (SELECT COUNT(*) FROM public.paraderos_osm) AS total_osm,
    (SELECT COUNT(*) FROM public.paraderos_osm o 
     WHERE NOT EXISTS (
         SELECT 1 FROM gtfs_stops g WHERE ST_DWithin(o.geom, g.geom, 50)
     )) AS osm_sin_gtfs_50m;


\echo '--- Ejecutando P4: Kilómetros de recorrido por comuna (ST_Intersection) ---'
SELECT 
    cs.comuna AS nom_comuna,
    COUNT(DISTINCT r.shape_id) AS shapes_que_cruzan,
    COUNT(DISTINCT r.route_short_name) AS rutas_distintas,
    ROUND((SUM(ST_Length(ST_Intersection(r.geom, cs.geom))) / 1000.0)::numeric, 2) AS km_recorridos
FROM public.comunas_sub cs
JOIN public.recorridos r ON ST_Intersects(r.geom, cs.geom)
GROUP BY cs.comuna
ORDER BY km_recorridos DESC;


\echo '--- Ejecutando P5: Vecino más cercano (KNN con CROSS JOIN LATERAL y <->) ---'
WITH paraderos_ruta AS (
    SELECT DISTINCT p.stop_id, p.stop_name, p.geom
    FROM public.paraderos_gtfs p
    JOIN gtfs_raw.stop_times st ON st.stop_id = p.stop_id
    JOIN gtfs_raw.trips t ON t.trip_id = st.trip_id
    JOIN gtfs_raw.routes r ON r.route_id = t.route_id
    WHERE r.route_short_name = '210'
)
SELECT 
    pr.stop_id,
    pr.stop_name,
    salud.id AS amenity_id,
    salud.amenity AS tipo_salud,
    salud.name AS nombre_salud,
    ROUND(ST_Distance(pr.geom, salud.geom)::numeric, 1) AS distancia_m
FROM paraderos_ruta pr
CROSS JOIN LATERAL (
    SELECT a.id, a.amenity, a.name, a.geom
    FROM public.amenidades a
    WHERE a.amenity IN ('pharmacy', 'hospital', 'clinic', 'doctors')
    ORDER BY pr.geom <-> a.geom
    LIMIT 1
) salud
ORDER BY distancia_m ASC
LIMIT 15;


\echo '--- Ejecutando P6: Grilla hexagonal de 500m ---'
-- La vista materializada mv_grilla (y mv_q1_densidad) se define en sql/8_mapas.sql: misma fuente que los mapas.
\i /sql/8_mapas.sql

-- Top 10: mayor razón edificios / (recorridos + 1), solo celdas interiores a la zona
SELECT rank_top, id AS celda_id, n_edificios, n_recorridos, n_shapes
FROM mv_grilla
WHERE rank_top IS NOT NULL
ORDER BY rank_top;


\echo '--- Ejecutando P7 (Propia): Cruce frecuencia de viajes GTFS vs Amenidades OSM a 100m ---'
SELECT 
    p.stop_id,
    p.stop_name,
    v.n_viajes,
    COUNT(a.id) AS amenidades_a_100m,
    COUNT(DISTINCT a.amenity) AS tipos_amenidades_distintos
FROM public.paraderos_gtfs p
JOIN public.viajes_por_paradero v ON v.stop_id = p.stop_id
LEFT JOIN public.amenidades a ON ST_DWithin(p.geom, a.geom, 100)
WHERE p.location_type IS NULL OR p.location_type = '0' OR p.location_type = ''
GROUP BY p.stop_id, p.stop_name, v.n_viajes
ORDER BY v.n_viajes DESC
LIMIT 15;