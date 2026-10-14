-- Etapa 6: índices (el ANALYZE lo hace cargar.sh al final)
-- 

CREATE INDEX idx_calles_geom          ON calles          USING gist (geom);
CREATE INDEX idx_calles_highway       ON calles          (highway);
CREATE INDEX idx_edificios_geom       ON edificios       USING gist (geom);
CREATE INDEX idx_edificios_geom_pt    ON edificios       USING gist (geom_pt);
CREATE INDEX idx_paraderos_osm_geom   ON paraderos_osm   USING gist (geom);
CREATE INDEX idx_amenidades_geom      ON amenidades      USING gist (geom);
CREATE INDEX idx_amenidades_amenity   ON amenidades      (amenity);
CREATE INDEX idx_paraderos_gtfs_geom  ON paraderos_gtfs  USING gist (geom);
CREATE INDEX idx_recorridos_geom      ON recorridos      USING gist (geom);
CREATE INDEX idx_recorridos_ruta      ON recorridos      (route_short_name);
CREATE INDEX idx_comunas_sub_geom     ON comunas_sub     USING gist (geom);
CREATE INDEX idx_zona_geom            ON zona            USING gist (geom);
-- comunas_cl ya trae su GIST sobre geom desde comunas_cl.sql
