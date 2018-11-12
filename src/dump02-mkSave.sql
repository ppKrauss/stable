/**
 * Make the dumps, save all as GeoJSON or CSV files.
 */

SELECT  stable.mkdump_save_city_test(); -- gera GeoJSON de cada municipio-teste.

-- funciona mas demora, rodar em BAT.
-- CSV de todos os pontos, quebrando em blocos conforme prefixo Geohash.
SELECT name_path, copy_csv(
  'addr_'||ag.gh_prefix||'.csv', -- gh_prefix
  $$
    SELECT geohash, osm_id, postcode, street, housenumber, name, other_tags
    FROM stable.vw_point_addr_city
    WHERE city_id=
  $$ || ag.city_id,
  true --ct.name_path
) copiou
FROM stable.city_test_names ct INNER JOIN stable.vw_point_addr_agghash2 ag
  ON stable.getcity_rels_id(ct.name_path)=ag.city_id
;

-- exemplo rápido.
COPY (
  SELECT DISTINCT
    --('{"6gky":0,"6gkz":1,"6gmn":2,"6gmp":3}'::jsonb)->>substr(a.geohash,1,4)
    -- || substr(a.geohash,5) geohash,
    a.geohash
    a.osm_id, a.postcode, a.street,
    a.housenumber, a.name, a.other_tags
  FROM stable.vw_point_addr a, (
    SELECT stable.getcity_polygon_geom('PR/Curitiba')
  ) t(geom_city)
  WHERE geom_city && a.way AND st_contains(geom_city,a.way)
  ORDER BY 1
) TO '/tmp/stable/addr.csv' CSV HEADER
;-- 2466


--('{"6gky":0,"6gkz":1,"6gmn":2,"6gmp":3}'::jsonb)->>substr(a.geohash,1,4)
-- || substr(a.geohash,5) geohash,

-- uma coisa de cada vez, por hora apenas prefixo 4.
-- para usar com copy_csv:
