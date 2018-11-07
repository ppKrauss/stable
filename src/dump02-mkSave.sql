/**
 * Make the dumps, save all as GeoJSON or CSV files.
 */

SELECT  stable.mkdump_save_city_test();

COPY (
  SELECT DISTINCT
    ('{"6gky":0,"6gkz":1,"6gmn":2,"6gmp":3}'::jsonb)->>substr(a.geohash,1,4)
    || substr(a.geohash,5) geohash,
    a.osm_id, a.postcode, a.street,
    a.housenumber, a.name, a.other_tags
  FROM stable.vw_point_addr a, (
    SELECT stable.getcity_polygon_geom('PR/Curitiba')
  ) t(geom_city)
  WHERE geom_city && a.way AND st_contains(geom_city,a.way)
  ORDER BY 1
) TO '/tmp/stable/curitiba_addr.csv' CSV HEADER
;-- 2466
