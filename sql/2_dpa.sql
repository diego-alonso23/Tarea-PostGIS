-- Etapa 2: DPA (después de cargar comunas_cl.sql)
-- comunas_sub = ST_Subdivide de las comunas que tocan la zona

DO $$
BEGIN
  IF Find_SRID('public','comunas_cl','geom') <> 5361 THEN
    RAISE EXCEPTION 'comunas_cl no está en SRID 5361';
  END IF;
END $$;

INSERT INTO etl_log(paso, detalle, n)
SELECT 'dpa', 'comunas totales en comunas_cl', count(*) FROM comunas_cl;
INSERT INTO etl_log(paso, detalle, n)
SELECT 'dpa', 'comunas con geometria invalida (se reparan solo en comunas_sub)', count(*)
FROM comunas_cl WHERE NOT ST_IsValid(geom);

-- ST_Subdivide para los joins pesados; solo las comunas que tocan la zona
DROP TABLE IF EXISTS comunas_sub;
CREATE TABLE comunas_sub AS
SELECT c.cut_com, c.comuna,
       ST_Subdivide(ST_MakeValid(c.geom), 256) AS geom
FROM comunas_cl c, zona z
WHERE ST_Intersects(c.geom, z.geom);
ALTER TABLE comunas_sub ALTER COLUMN geom TYPE geometry(Polygon, 5361)
  USING ST_CollectionExtract(geom, 3);
