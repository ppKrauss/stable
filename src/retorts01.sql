-- SAVE REPORTS
--
-- AFTER SH:
-- sudo rm -r /tmp/reports
-- sudo -u postgres mkdir /tmp/reports

COPY (
 select jsonb_object_keys(tags) k, count(*) n
 from planet_osm_point
 group by 1 order by 2 desc, 1
) TO '/tmp/reports/points_report01-keys.csv' CSV HEADER
;-- 2241

COPY (SELECT * FROM stable.vw_city_test_report01)
TO '/tmp/reports/city_test_report01.csv' CSV HEADER
;-- 21

COPY (
  SELECT c.name_path, t.geocode,
         round(t.perc_geom,1) perc_geom,
         round(t.perc_cell,1) perc_cell
  FROM stable.city_test_names c,
  LATERAL st_geocode_cover(
    stable.getcity_polygon_geom(c.name_path),
    '',
    'geohash',
    3
  ) t
) TO '/tmp/reports/city_test_geohashes.csv' CSV HEADER
;
/* mesmo que:
SELECT copy_csv(
  'reports/city_test_report01.csv'
  'SELECT * FROM stable.vw_city_test_report01'
);
*/

-- FINAL SH:
-- cp /tmp/reports/*_report*.* /opt/gits/OSM/stable/data/reports


/*

SELECT city_id, r.tags->'name' as cidade, count(*) n
FROM stable.vw_city_test_inside_points w
inner join planet_osm_rels r ON r.id=city_id group by 1,2
;

-- multireport
SELECT jsonb_build_object(
    'vw_city_test_report01', (
      select jsonb_agg(to_jsonb(t)) from stable.vw_city_test_report01 t
    ),
    'vw_sampa_test_report01', (
      select jsonb_agg(to_jsonb(t)) from stable.vw_sampa_test_report01 t
  )

-- json output
COPY (
  SELECT jsonb_agg(to_jsonb(t)) from stable.vw_city_test_report01 t
  ) TO '/tmp/reports/test_report01-counts.json'
;
*/
