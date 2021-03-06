ALTER TABLE planet_osm_rels alter column members
  type jsonb USING  jsonb_object(members)
; -- fazer o com update até estar seguro. Depois trocar por stable.osmmembers_pack(jsonb_object(members));
UPDATE planet_osm_rels
SET members=COALESCE(stable.members_pack(id), members);

-- demora 15 min cada:
ALTER TABLE planet_osm_line alter column tags type jsonb
      USING stable.osm_to_jsonb(tags,true);
ALTER TABLE planet_osm_roads alter column tags type jsonb
      USING stable.osm_to_jsonb(tags,true);
ALTER TABLE planet_osm_ways alter column tags type jsonb
      USING stable.osm_to_jsonb(tags,true); -- ~10 min

-- mais rapidos:
ALTER TABLE planet_osm_polygon alter column tags type jsonb
      USING stable.osm_to_jsonb(tags,true);
ALTER TABLE planet_osm_rels alter column tags type jsonb
      USING stable.osm_to_jsonb(tags,true);

-- 15 min:
ALTER TABLE planet_osm_point alter column tags type jsonb USING stable.osm_to_jsonb(tags,true);

-- Opcional. Lines e Roads são dupliacadas mesmo com --multi-geometry
ALTER TABLE planet_osm_line ADD COLUMN osm_id2 int;
UPDATE planet_osm_line
 SET  osm_id2 = sub_id
 FROM (
   SELECT osm_id, way, row_number() OVER (PARTITION BY osm_id) as sub_id
   FROM planet_osm_line
 ) t WHERE t.osm_id=planet_osm_line.osm_id AND t.way=planet_osm_line.way
;
ALTER TABLE planet_osm_line ALTER COLUMN osm_id2 SET NOT NULL;
ALTER TABLE planet_osm_line ADD CONSTRAINT osmline_uniqids UNIQUE(osm_id,osm_id2);

-- Opcional:
/* deu pau, anulando 'name:' ... revisar depois quando for usar.
UPDATE planet_osm_polygon -- ~10 minutos. 4.396.944 linhas.
 SET tags = stable.tags_split_prefix(jsonb_strip_nulls_v2(tags));
UPDATE planet_osm_line   --  ~9 minutos. 3.869.230 linhas
 SET tags = stable.tags_split_prefix(jsonb_strip_nulls_v2(tags));
UPDATE planet_osm_rels   --  ~1 minuto. 151.288 linhas
 SET tags = stable.tags_split_prefix(jsonb_strip_nulls_v2(tags));
*/
UPDATE planet_osm_polygon
 SET tags = jsonb_strip_nulls_v2(tags);
UPDATE planet_osm_line
 SET tags = jsonb_strip_nulls_v2(tags);
UPDATE planet_osm_rels
 SET tags = jsonb_strip_nulls_v2(tags);





--------
-- -- -- -- -- -- --
-- member_of

-- script para rodar em BAT:
-- criar função que roda toda a sequência.
DELETE FROM stable.member_of;
INSERT INTO stable.member_of(osm_owner, osm_type, osm_id, member_type)
  SELECT DISTINCT -p.id, substr(k,1,1), substr(k,2)::bigint, t.mtype
  FROM planet_osm_rels p, LATERAL jsonb_each_text(p.members) t(k,mtype)
; -- tot 1280006
-- select osm_type,count(*) n  from stable.member_of group by 1;
-- n        |  124441
-- r        |    2683
-- w        | 1152882

DELETE FROM stable.member_of m
WHERE osm_type='r' AND NOT EXISTS (
  -- same_optimized_from osm_id NOT IN (id planet_osm_rels)
  SELECT 1 FROM planet_osm_rels x
  WHERE x.id=m.osm_id
); -- 182 de 2683.
DELETE FROM stable.member_of m
WHERE osm_type='w' AND NOT EXISTS (
  SELECT 1 FROM planet_osm_ways x
  WHERE x.id=m.osm_id
); -- 15830 de 1152882.
DELETE FROM stable.member_of m
WHERE osm_type='n' AND NOT EXISTS (
  SELECT 1 FROM planet_osm_nodes x
  WHERE x.id=m.osm_id
); -- 317 de 124441.
/* não precisa pois não ofereceu conflito e ways.nodes não requer jsonb
INSERT INTO stable.member_of(osm_owner, osm_type, osm_id, member_type)
  SELECT DISTINCT p.id, 'n', t.node_id, NULL
  FROM planet_osm_ways p, LATERAL unnest(p.nodes) t(node_id)
  WHERE t.node_id IN (SELECT id FROM planet_osm_nodes) -- EXISTS
; -- 103426850
*/

-- SELECT member_type, count(*) n FROM stable.member_of group by 1 order by 2 desc,1;
-- usar os mais frquentes apenas .

/* DESCARTADO POR SER REDUNDANTE, usar md5-bigint
ALTER TABLE planet_osm_ways add column nodes_md5 text;
CREATE INDEX posm_nodes_md5_idx ON planet_osm_ways(nodes_md5);
UPDATE planet_osm_ways SET nodes_md5 = md5(nodes::text); -- array_distinct_sort(nodes)
-- select count(*) from (select nodes_md5 from planet_osm_ways group by 1 having count(*)>1) t;
-- 12468
*/
ALTER TABLE planet_osm_ways add column nodes_md5_int bigint;
CREATE INDEX posm_nodes_md5int_idx ON planet_osm_ways(nodes_md5_int);
UPDATE planet_osm_ways
SET nodes_md5_int = ('x'||substr(md5(nodes::text),0,17))::bit(64)::bigint
;  -- 8335298
-- select count(*) from (select nodes_md5_int from planet_osm_ways group by 1 having count(*)>1) t;
-- 12468
-- 11% as ways são compostas de apenas 2 nós.

-------
-- Gestão das geometrias duplicadas.


ALTER TABLE planet_osm_rels add column members_md5_int bigint;
CREATE INDEX rels_members_md5_int ON planet_osm_rels(members_md5_int);
UPDATE planet_osm_rels -- basta verificar ways, aí analisar com parts ou rels.
SET members_md5_int = ('x'||stable.member_md5key(members,true,''))::bit(64)::bigint
;  -- 151288

/* CONFERINDO:
SELECT count(*) from (
 select members_md5_int g, count(*)
 from planet_osm_rels group by 1 having count(*)>1
) t;
-- =  4761

SELECT id, members, tags from planet_osm_rels
WHERE
  members_md5_int IN (
    select members_md5_int
    from planet_osm_rels group by 1 having count(*)>1)
  AND members_md5_int NOT IN (
    SELECT DISTINCT members_md5_int from (
      select members_md5_int, stable.member_md5key(members) g
      from planet_osm_rels group by 1,2 having count(*)>1
  ) t
);
-- destaca rotas de onibus (relation com uma só way),
-- e casos complexos com subarea, como país Bolivia e Uruguai.
*/


-- -- -- -- -- -- --
-- -- -- -- -- -- --
-- -- -- -- -- -- --
-- is_dup
-- Fora de uso?  falta revisão final.

ALTER TABLE planet_osm_polygon add column is_dup boolean DEFAULT false;

UPDATE planet_osm_polygon t
SET is_dup = true
WHERE osm_id<0 AND EXISTS (
  SELECT 1 FROM planet_osm_rels
  WHERE (id != (-t.osm_id)) AND members_md5_int=(
    SELECT members_md5_int FROM planet_osm_rels WHERE id=-t.osm_id
  )
); -- 3493
UPDATE planet_osm_polygon t
SET is_dup = true
WHERE not(is_dup) AND osm_id>0 AND EXISTS (
  SELECT 1 FROM planet_osm_ways
  WHERE (id != t.osm_id) AND nodes_md5_int=(
    SELECT nodes_md5_int FROM planet_osm_ways WHERE id=t.osm_id
  )
); -- 30882 lines, ~10mins


ALTER TABLE planet_osm_line add column is_dup boolean DEFAULT false;
UPDATE planet_osm_line t
SET is_dup = true
WHERE osm_id<0 AND EXISTS (
  SELECT 1 FROM planet_osm_rels
  WHERE (id != (-t.osm_id)) AND members_md5_int=(
    SELECT members_md5_int FROM planet_osm_rels WHERE id=-t.osm_id
  )
); --  7304 lines de 72895
UPDATE planet_osm_line t
SET is_dup = true
WHERE not(is_dup) AND osm_id>0 AND EXISTS (
  SELECT 1 FROM planet_osm_ways
  WHERE (id != t.osm_id) AND nodes_md5_int=(
    SELECT nodes_md5_int FROM planet_osm_ways WHERE id=t.osm_id
  )
); -- 940 in 3.796.335 linhas , ~10min





-- -- -- -- -- --
-- -- -- -- -- --
-- -- -- -- -- --
---- AFTER ALL JSONb UPDATES
-- LIB based on jsonb tags

CREATE or replace FUNCTION stable.getcity_rels_id(
  p_cod_ibge text  -- código IBGE do município, wikidata-id, lex-name ou path-name
  ,p_admin_level text default '8'
) RETURNS bigint AS $f$
 SELECT id
 FROM planet_osm_rels
 WHERE tags->>'admin_level'=p_admin_level AND CASE
	  WHEN substr(p_cod_ibge,1,1)='Q' THEN p_cod_ibge=tags->>'wikidata'
	  WHEN substr(p_cod_ibge,3,1) IN (':','-',';') THEN (
	    SELECT ibge_id::text FROM brcodes_city
	    WHERE upper(substr(p_cod_ibge,1,2))=uf AND substr(lower(p_cod_ibge),4)=lexLabel
	  ) = tags->>'IBGE:GEOCODIGO'
	  WHEN substr(p_cod_ibge,3,1)='/' THEN (
	    SELECT ibge_id::text FROM brcodes_city
	    WHERE upper(substr(p_cod_ibge,1,2))=uf AND substr(p_cod_ibge,4)=stable.lexlabel_to_path(lexLabel)
	  ) = tags->>'IBGE:GEOCODIGO'
	  WHEN length(p_cod_ibge)=7 THEN p_cod_ibge=tags->>'IBGE:GEOCODIGO'
	  ELSE p_cod_ibge::bigint = (tags->>'IBGE:GEOCODIGO')::bigint
  END
$f$ LANGUAGE SQL IMMUTABLE;
COMMENT ON FUNCTION stable.getcity_rels_id(text,text)

CREATE or replace FUNCTION stable.getcity_rels_id(
  p_cod_ibge bigint  -- código IBGE do município
  ,p_admin_level text default '8'
) RETURNS bigint AS $wrap$
   SELECT stable.getcity_rels_id($1::text,$2)
$wrap$ LANGUAGE SQL IMMUTABLE;

/*- -
 SELECT ibge_id, stable.getcity_rels_id(ibge_id) osm_id FROM brcodes_city;

 select stable.getcity_rels_id('4304408');   -- IBGE ID
 select stable.getcity_rels_id('0004304408');
 select stable.getcity_rels_id('rS-canEla'); -- namePath, case ins.
 select stable.getcity_rels_id('RS/Canela'); -- namePath, case sens.
 select stable.getcity_rels_id('Q995318');  -- wikidata

 select stable.getcity_rels_id('SP/SaoCarlos');  -- other name-path
*/

CREATE or replace FUNCTION stable.getcity_polygon_geom(
  p_cod_ibge text  -- código IBGE do município. Completo ou parcial.
  ,p_admin_level text default '8'
) RETURNS geometry AS $f$
 SELECT way
 FROM planet_osm_polygon
 WHERE -osm_id = stable.getcity_rels_id(p_cod_ibge,$2)
$f$ LANGUAGE SQL IMMUTABLE;

--SELECT osm_id, round(st_area(way,true)) as area_m2, tags->'name' as name
-- FROM planet_osm_polygon p, (select stable.getcity_polygon_geom('SP/MonteiroLobato')) t(geom)
-- WHERE p.way && t.geom AND st_contains(t.geom,way) and not(st_equals(way,t.geom));

/*
CREATE or replace FUNCTION stable.getcity_line_geom(
  p_cod_ibge text  -- código IBGE do município. Completo ou parcial.
  ,p_admin_level text default '8'
) RETURNS geometry AS $f$
 SELECT way
 FROM planet_osm_line
 WHERE -osm_id = stable.getcity_rels_id(p_cod_ibge,$2)
$f$ LANGUAGE SQL IMMUTABLE;
*/
