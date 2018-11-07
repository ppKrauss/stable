/**
 * Make-dump LIB and make it.
 */
CREATE or replace FUNCTION stable.mkdump_save_city_test(
  p_root text DEFAULT '/tmp/'
) RETURNS table(city_name text, osm_id bigint, filename text) AS $f$
  SELECT t1.name_path, t1.id,
   file_put_contents(replace(t1.name_path,'/','-')||'.json', jsonb_pretty((
    SELECT
       ST_AsGeoJSONb( (SELECT way FROM planet_osm_polygon WHERE osm_id=-r1.id), 6, 1, 'R'||r1.id::text,
         jsonb_strip_nulls(stable.rel_properties(r1.id)
         || COALESCE(stable.rel_dup_properties(r1.id,'r',r1.members_md5_int,r1.members),'{}'::jsonb) )
      )
    FROM  planet_osm_rels r1 where r1.id=t1.id
  )), '',p_root ) -- /selct /pretty /file
  FROM (
   SELECT *, stable.getcity_rels_id(name_path) id  from stable.city_test_names
  ) t1, LATERAL (
   SELECT * FROM planet_osm_rels r WHERE  r.id=t1.id
  ) t2;
$f$ LANGUAGE SQL IMMUTABLE;
-- select * from  stable.save_city_test_names();


CREATE or replace FUNCTION stable.mkdump_save_addr_test(
    p_root text DEFAULT '/tmp/'
) RETURNS table(city_name text, osm_id bigint, filename text) AS $f$
copy_csv(name_path||'/address.csv'
  p_filename  text,
  p_query     text,
  true, p_root

SELECT t1.name_path, t1.id,
 file_put_contents(replace(t1.name_path,'/','-')||'.json', jsonb_pretty((
  SELECT
     ST_AsGeoJSONb( (SELECT way FROM planet_osm_polygon WHERE osm_id=-r1.id), 6, 1, 'R'||r1.id::text,
       jsonb_strip_nulls(stable.rel_properties(r1.id)
       || COALESCE(stable.rel_dup_properties(r1.id,'r',r1.members_md5_int,r1.members),'{}'::jsonb) )
    )
  FROM  planet_osm_rels r1 where r1.id=t1.id
)), '',p_root ) -- /selct /pretty /file
FROM (
 SELECT *, stable.getcity_rels_id(name_path) id  from stable.city_test_names
) t1, LATERAL (
 SELECT * FROM planet_osm_rels r WHERE  r.id=t1.id
) t2;

$f$ LANGUAGE SQL IMMUTABLE;
