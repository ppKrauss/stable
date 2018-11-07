/**
 * City OSM dumps: functions and procedures to generate the GeoJSON dumps, city scale.
 * All stable.city* namespace.
 * See stable.city_test_* namespace for starting tests for new features.
 */

DROP TABLE IF EXISTS stable.city_test_names;
CREATE TABLE stable.city_test_names AS
  SELECT unnest(
    '{PR/Curitiba,PR/MarechalCandidoRondon,SC/JaraguaSul,SP/MonteiroLobato,MG/SantaCruzMinas,SP/SaoPaulo,PA/Altamira,RJ/AngraReis}'::text[]
  ) name_path
;


------

--------------
-- Apoio ao sample-tests:

CREATE TABLE stable.city_test_inside AS
  WITH t AS (
   SELECT  q.id, c.name_path, stable.getcity_polygon_geom(c.name_path) geom
   FROM stable.city_test_names c, LATERAL (
     SELECT stable.getcity_rels_id(c.name_path)) q(id)
  )
  SELECT t.id city_id, p.osm_id
  FROM planet_osm_polygon p, t
  WHERE p.way && t.geom and not(st_equals(way,t.geom)) AND st_contains(t.geom,way)
  UNION
  SELECT t.id, p.osm_id FROM planet_osm_line p, t
  WHERE p.way && t.geom AND st_contains(t.geom,way)
  UNION
  SELECT t.id, p.osm_id FROM planet_osm_roads p, t
  WHERE p.way && t.geom AND st_contains(t.geom,way)
;  -- 1743785
COMMENT ON TABLE stable.city_test_inside
IS 'Poligonos e linhas integralmente internos ao município-teste.';
-- use SELECT DISTINCT osm_id FROM stable.city_test_inside;

CREATE VIEW stable.vw_city_test_inside_points AS
  WITH t AS (
   SELECT  q.id, c.name_path, stable.getcity_polygon_geom(c.name_path) geom
   FROM stable.city_test_names c, LATERAL (
     SELECT stable.getcity_rels_id(c.name_path)) q(id)
  )
  SELECT t.id city_id, p.osm_id
  FROM planet_osm_point p, t
  WHERE t.geom && p.way AND st_contains(t.geom,p.way)
;

-- -- -- -- --
-- REPORTS, lib e views de apoio.

-- contagem direta dos elementos
CREATE or replace VIEW stable.vw_city_test_report01 AS
  WITH t AS (
    SELECT DISTINCT 'Cidades' escopo, osm_id
     FROM stable.city_test_inside
     WHERE city_id!=stable.getcity_rels_id('SP/SaoPaulo')
    UNION
    SELECT 'Sampa' escopo, osm_id
     FROM stable.city_test_inside
     WHERE city_id=stable.getcity_rels_id('SP/SaoPaulo')
  )
  SELECT t.escopo, 'r' as osm_type, tags->>'type' as tagtype
    ,count(*) num
    ,count(*) FILTER(WHERE tags?'wikidata') AS num_wikidata
    ,count(*) FILTER(WHERE tags?'name') AS num_name
  FROM planet_osm_rels INNER JOIN t ON t.osm_id=-id
  group by 1,2,3
  UNION
  SELECT t.escopo, 'w' as osm_type, tags->>'type' as tagtype
    ,count(*) n
    ,count(*) FILTER(WHERE tags?'wikidata') AS n_wikidata
    ,count(*) FILTER(WHERE tags?'name') AS n_name
  FROM planet_osm_ways INNER JOIN t ON t.osm_id=id
  group by 1,2,3

  UNION
  SELECT 'Munic. de '||(r.tags->>'name') as escopo,
         'n' as osm_type, '-' as tagtype
    ,count(*) n, NULL,NULL
  FROM stable.vw_city_test_inside_points w
  inner join planet_osm_rels r ON r.id=city_id group by 1,2,3

  ORDER BY 1,2,3,4
;

------
--- aux reports:

CREATE or replace VIEW stable.vw_point_addr AS
  SELECT st_geohash(way,9) as geohash, osm_id,
       tags->>'addr:housenumber' AS postcode,
       tags->>'addr:street' AS street,
       tags->>'addr:housenumber' AS housenumber,
       tags->>'name' AS name,
       stable.tags_to_csv(tags - array['addr:city','addr:street','addr:housenumber','name']) other_tags,
       way
  FROM planet_osm_point
  WHERE tags?'addr:street' AND tags?'addr:housenumber'
;
