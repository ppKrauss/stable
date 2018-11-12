/**
 * City OSM dumps: functions and procedures to generate the GeoJSON dumps, city scale.
 * All stable.city* namespace.
 * See stable.city_test_* namespace for starting tests for new features.
 */

CREATE view vw_osm_city_polygon AS -- all 5570 cities
  SELECT p.*, c.*
  FROM vw_brcodes_city_filepath c inner join planet_osm_polygon p
    ON c.ibge_id::text=p.tags->>'IBGE:GEOCODIGO' and p.tags?'admin_level'
;
-- e.g. SELECT count(*) from ibge_lim_munic_2017  i INNER JOIN vw_osm_city_polygon p ON i.geocodigo::int=p.ibge_id;


DROP TABLE IF EXISTS stable.city_test_names;
CREATE TABLE stable.city_test_names AS
  SELECT unnest(
    '{PR/Curitiba,PR/MarechalCandidoRondon,SC/JaraguaSul,SP/MonteiroLobato,MG/SantaCruzMinas,SP/SaoPaulo,PA/Altamira,RJ/AngraReis}'::text[]
  ) name_path
;


CREATE or replace VIEW stable.vw_point_addr AS
  SELECT st_geohash(way,12) as geohash,
  -- tamanho 12 garante reverter em LatLong de 6 digitos decimais
       osm_id,
       tags->>'addr:housenumber' AS postcode,
       tags->>'addr:street' AS street,
       tags->>'addr:housenumber' AS housenumber,
       tags->>'name' AS name,
       stable.tags_to_csv(tags - array['addr:city','addr:street','addr:housenumber','name']) other_tags,
       way
  FROM planet_osm_point
  WHERE tags?'addr:street' AND tags?'addr:housenumber'
;

--------------
-- Apoio ao sample-tests:

CREATE VIEW stable.vw_city_test_geom AS -- reused
  SELECT  q.id city_id, c.name_path, stable.getcity_polygon_geom(c.name_path) geom
  FROM stable.city_test_names c, LATERAL (
    SELECT stable.getcity_rels_id(c.name_path)
  ) q(id)
;

CREATE or replace VIEW stable.vw_point_addr_city AS
  SELECT DISTINCT
    c.city_id, substr(a.geohash,1,4) as gh_prefix,
    a.geohash, a.osm_id, a.postcode, a.street,
    a.housenumber, a.name, a.other_tags
  FROM stable.vw_point_addr a INNER JOIN stable.vw_city_test_geom c
    ON c.geom && a.way AND st_contains(c.geom,a.way)
  ORDER BY 1,2,3
;

/*
CREATE MATERIALIZED VIEW stable.vw_point_addr_agghash AS
  SELECT city_id, gh_prefix, count(*) n
  FROM stable.vw_point_addr_city
  GROUP BY 1,2
  ORDER BY 1,2
;
-- Ver algoritmo de balanço dos prefixos.
-- .. enquanto isso, manual.
*/
CREATE TABLE stable.vw_point_addr_agghash2 (
 city_id  bigint,
 len int,
 gh_prefix text,
 n   int
);
INSERT INTO stable.vw_point_addr_agghash2 VALUES
 (185554, 3, '6z6', 2),
 (296625  , 3  , '6gm' , 5+242+2),
 (297687  , 3  , '6g9'      ,     5),
 (297514 ,3 , '6gk'      ,   179+2205),
 (297514 ,3 , '6gm'      ,    68+14),
 (298285 , 3, '6gy'      ,     9+38+2),
 (298285 , 4,'6gyc'      , 14107),
 (298285 , 4,'6gyf'      , 37428),
 (298285 , 3,'6gz'      ,    14+25),
 (298450 , 4 , '6gzm'      ,     2),
 (2217370 , 3 , '75b'      ,     1+5+6+1)
;
-----

CREATE TABLE stable.city_test_inside AS
  SELECT t.city_id, p.osm_id
  FROM planet_osm_polygon p, stable.vw_city_test_geom t
  WHERE p.way && t.geom and not(st_equals(way,t.geom)) AND st_contains(t.geom,way)
  UNION
  SELECT t.city_id, p.osm_id FROM planet_osm_line p, stable.vw_city_test_geom t
  WHERE p.way && t.geom AND st_contains(t.geom,way)
  UNION
  SELECT t.city_id, p.osm_id FROM planet_osm_roads p, stable.vw_city_test_geom t
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
