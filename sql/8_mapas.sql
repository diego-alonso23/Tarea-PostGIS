-- Vistas que alimentan los mapas (Q1 densidad por comuna, Q6 grilla hexagonal).
-- Fuente única: la usan sql/7_consultas.sql (\i) y scripts/exportar_mapas.sh.

-- ---- Q1: densidad por comuna, sobre el área de la comuna DENTRO de la zona ----
DROP MATERIALIZED VIEW IF EXISTS mv_q1_densidad CASCADE;
CREATE MATERIALIZED VIEW mv_q1_densidad AS
WITH rec AS (
  SELECT c.cut_com, c.comuna,
         ST_Area(c.geom) / 1e6 AS area_comuna_km2,
         ST_Multi(ST_CollectionExtract(ST_Intersection(c.geom, z.geom), 3)) AS geom
  FROM comunas_cl c JOIN zona z ON ST_Intersects(c.geom, z.geom)
)
SELECT r.cut_com, r.comuna,
       round(r.area_comuna_km2::numeric, 2)                                AS area_comuna_km2,
       round((ST_Area(r.geom) / 1e6)::numeric, 2)                          AS area_zona_km2,
       round((100 * ST_Area(r.geom) / 1e6 / r.area_comuna_km2)::numeric, 1) AS pct_comuna_en_zona,
       count(p.stop_id)                                                    AS n_paraderos,
       round((count(p.stop_id) / NULLIF(ST_Area(r.geom) / 1e6, 0))::numeric, 2) AS paraderos_km2,
       r.geom::geometry(MultiPolygon, 5361)                                AS geom
FROM rec r
LEFT JOIN paraderos_gtfs p
  ON ST_Intersects(r.geom, p.geom)
 AND (p.location_type IS NULL OR p.location_type IN ('', '0'))
GROUP BY r.cut_com, r.comuna, r.area_comuna_km2, r.geom;

-- ---- Q6: grilla hexagonal de 500 m (lado) ---------------------------------
-- n_edificios: punto interior del edificio dentro de la celda (cada edificio cuenta una vez).
-- n_recorridos: route_short_name distintos cuyos shapes cruzan la celda.
-- interior: celda completamente dentro de la zona. Los edificios (OSM) solo existen dentro de
--   la caja, pero los recorridos se guardan completos, así que las celdas de borde subcuentan
--   edificios; por eso el ranking usa solo celdas interiores.
-- rank_top: 10 celdas con mayor n_edificios / (n_recorridos + 1), desempate por n_edificios.
DROP MATERIALIZED VIEW IF EXISTS mv_grilla CASCADE;
CREATE MATERIALIZED VIEW mv_grilla AS
WITH celdas AS (
  SELECT row_number() OVER (ORDER BY g.i, g.j) AS id, g.geom,
         ST_Within(g.geom, z.geom) AS interior
  FROM zona z, LATERAL ST_HexagonGrid(500.0, z.geom) g
),
e AS (SELECT c.id, count(*) AS n FROM celdas c
      JOIN edificios b ON ST_Intersects(c.geom, b.geom_pt) GROUP BY c.id),
r AS (SELECT c.id, count(DISTINCT x.route_short_name) AS n, count(DISTINCT x.shape_id) AS n_shapes
      FROM celdas c JOIN recorridos x ON ST_Intersects(c.geom, x.geom) GROUP BY c.id),
t AS (
  SELECT c.id, c.geom, c.interior,
         COALESCE(e.n, 0) AS n_edificios, COALESCE(r.n, 0) AS n_recorridos,
         COALESCE(r.n_shapes, 0) AS n_shapes
  FROM celdas c LEFT JOIN e USING (id) LEFT JOIN r USING (id)
)
SELECT s.id, s.n_edificios, s.n_recorridos, s.n_shapes, s.interior,
       CASE WHEN s.rk <= 10 THEN s.rk END AS rank_top, s.geom
FROM (
  SELECT t.*,
         CASE WHEN t.interior AND t.n_edificios > 0 THEN
           row_number() OVER (PARTITION BY (t.interior AND t.n_edificios > 0)
                              ORDER BY t.n_edificios::numeric / (t.n_recorridos + 1) DESC,
                                       t.n_edificios DESC, t.id)
         END AS rk
  FROM t
) s;
CREATE INDEX idx_mv_grilla_geom ON mv_grilla USING gist (geom);
ANALYZE mv_grilla;
