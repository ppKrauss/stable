/**
 * Lib of functions and basic structures.
 */

CREATE EXTENSION IF NOT EXISTS PLpythonU; -- untrested Python2, ideal usar py3
CREATE EXTENSION IF NOT EXISTS unaccent; -- for unaccent()
CREATE EXTENSION IF NOT EXISTS fuzzyStrMatch; -- for metaphone() and levenshtein()
-- CREATE EXTENSION IF NOT EXISTS pgCrypto; -- for SHA1 and crc32.
CREATE EXTENSION IF NOT EXISTS file_fdw;
CREATE SERVER IF NOT EXISTS files FOREIGN DATA WRAPPER file_fdw;

CREATE SCHEMA IF NOT EXISTS stable; -- OSM BR Stable

CREATE TABLE stable.configs (
   lib_version text NOT NULL  -- this project version
   , base_path text NOT NULL -- can be any onwned by "postgres" user.
);
INSERT INTO stable.configs(lib_version,base_path) VALUES ('1.0.0','/tmp');

/*  Conferir se haverá uso posterior, senão bobagem só para inicialização:
CREATE  TABLE stable.element_exists(
   osm_id bigint NOT NULL -- negative is relation
  ,is_node boolean NOT NULL DEFAULT false
  ,UNIQUE(is_node,osm_id)
); -- for use with EXISTS(
   -- SELECT 1 FROM stable.element_exists WHERE is_node=t.x AND osm_id=t.y)
INSERT INTO stable.element_exists(is_node,osm_id)
  SELECT false,-id FROM planet_osm_rels;
INSERT INTO stable.element_exists(is_node,osm_id)
  SELECT false,id FROM planet_osm_ways;
INSERT INTO stable.element_exists(is_node,osm_id)
  SELECT true,id FROM planet_osm_nodes;
*/

CREATE TABLE stable.member_of(
  osm_owner bigint NOT NULL, -- osm_id of a relations
  osm_type char(1) NOT NULL, -- from split
  osm_id bigint NOT NULL, -- from split
  member_type text,
  UNIQUE(osm_owner, osm_type, osm_id)
);
CREATE INDEX stb_member_idx ON stable.member_of(osm_type, osm_id);

CREATE or replace FUNCTION stable.members_pack(
  p_owner_id bigint -- osm_id of a relation
) RETURNS jsonb AS $f$
  SELECT jsonb_object_agg(osm_type,member_types)
         || jsonb_object_agg(osm_type||'_size',n_osm_ids)
         || jsonb_object_agg(osm_type||'_md5', substr(osm_ids_md5,0,17)) --
  FROM (
    SELECT osm_type, SUM(n_osm_ids) n_osm_ids,
           jsonb_object_agg(member_type,osm_ids) member_types,
           md5(array_distinct_sort(array_agg_cat(osm_ids_md5))::text) osm_ids_md5
    FROM (
      SELECT osm_type, member_type,
             count(*) as n_osm_ids,
             jsonb_agg(osm_id ORDER BY osm_id) as osm_ids,
             array_agg(osm_id) as osm_ids_md5
      FROM stable.member_of
      WHERE osm_owner=-$1
      GROUP BY 1,2
    ) t1
    GROUP BY 1
  ) t2
$f$ LANGUAGE SQL IMMUTABLE;

-- SELECT member_type, count(*) n FROM stable.member_of group by 1 order by 2 desc,1;
-- usar os mais frquentes apenas .


---- ---

CREATE or replace FUNCTION stable.lexlabel_to_path(
  p_lexname text
) RETURNS text AS $f$
  SELECT string_agg(initcap(t),'')
  FROM regexp_split_to_table(p_lexname, E'[\\.\\s]+') t
$f$ LANGUAGE SQL IMMUTABLE;


CREATE or replace FUNCTION stable.osm_to_jsonb_remove() RETURNS text[] AS $f$
   SELECT array['osm_uid','osm_user','osm_version','osm_changeset','osm_timestamp'];
$f$ LANGUAGE SQL IMMUTABLE;

CREATE or replace FUNCTION stable.osm_to_jsonb_remove_prefix(
  jsonb,text default 'name:'
) RETURNS text[] AS $f$
  -- retorna lista de tags prefixadas, para subtrair do objeto.
  SELECT COALESCE((
    SELECT array_agg(t)
    FROM jsonb_object_keys($1) t
    WHERE position($2 in t)=1
  ), '{}'::text[])
$f$ LANGUAGE SQL IMMUTABLE;

CREATE or replace FUNCTION stable.tags_split_prefix(
  jsonb,
  text default 'name:'
) RETURNS jsonb AS $f$
  -- transforma objeto com prefixos em objeto com sub-objectos.
  SELECT ($1-stable.osm_to_jsonb_remove_prefix($1)) || jsonb_build_object($2,(
    SELECT jsonb_object_agg(substr(t1,t2.l+1),$1->t1)
    FROM jsonb_object_keys($1) t1, (select length($2) l) t2
    WHERE position($2 in t1)=1
  ))
$f$ LANGUAGE SQL IMMUTABLE;

CREATE or replace FUNCTION stable.osm_to_jsonb(
  p_input text[],
  p_strip boolean DEFAULT false
) RETURNS JSONb AS $f$
  SELECT CASE WHEN p_strip THEN jsonb_strip_nulls_v2(x) ELSE x END
  FROM (
    SELECT jsonb_object($1) - stable.osm_to_jsonb_remove()
  ) t(x)
$f$ LANGUAGE SQL IMMUTABLE;

CREATE or replace FUNCTION stable.osm_to_jsonb(
  p_input hstore,
  p_strip boolean DEFAULT false
) RETURNS JSONb AS $f$
  SELECT CASE WHEN p_strip THEN jsonb_strip_nulls_v2(x) ELSE x END
  FROM (
    SELECT hstore_to_jsonb_loose($1) - stable.osm_to_jsonb_remove()
  ) t(x)
$f$ LANGUAGE SQL IMMUTABLE;

CREATE or replace FUNCTION stable.member_md5key(
  p_members jsonb, -- input from planet_osm_rels
  p_no_rel boolean DEFAULT false, -- exclude rel-members
  p_w_char char DEFAULT 'w' -- or '' for hexadecimal output.
) RETURNS text AS $f$
  SELECT p_w_char || COALESCE($1->>'w_md5','') || CASE
    WHEN p_no_rel THEN ''
    ELSE 'r' || COALESCE($1->>'r_md5','')
  END
$f$ LANGUAGE SQL IMMUTABLE;

CREATE or replace FUNCTION stable.member_md5key(
  p_rel_id bigint,
  p_no_rel boolean DEFAULT false -- exclude rel-members
) RETURNS text AS $f$
  SELECT stable.member_md5key(members,p_no_rel)
  FROM planet_osm_rels WHERE id=p_rel_id
$f$ LANGUAGE SQL IMMUTABLE;
/*
select count(*) from (select stable.member_md5key(members,true) g, count(*) from planet_osm_rels group by 1 having count(*)>1) t;
-- =  4761
select count(*) from (select stable.member_md5key(members) g, count(*) from planet_osm_rels group by 1 having count(*)>1) t;
-- =  4752
select count(*) from (
    select parts g, count(*)
    from planet_osm_rels group by 1 having count(*)>1) t;
-- =   917
*/

CREATE or replace FUNCTION stable.members_seems_unpack(
  p_to_test jsonb,  -- the input JSON
  p_limit_tests int DEFAULT 5 -- use NULL to check all
) RETURNS boolean AS $f$
  SELECT substr(k,1,1)~'^[nwr]$' AND  substr(k,2)~'^[0-9]+$'
  FROM jsonb_each_text(p_to_test) t(k,gtype) LIMIT p_limit_tests
$f$ LANGUAGE SQL IMMUTABLE;

CREATE or replace FUNCTION stable.members_seems_pack(jsonb) RETURNS boolean AS $f$
  SELECT CASE WHEN jsonb_typeof($1)='object' AND (
     SELECT bool_and( jsonb_typeof($1->t) = 'object' )
     FROM (
       VALUES ('n'), ('w'), ('r')
     ) t(t)
   ) THEN true ELSE false END
$f$ LANGUAGE SQL IMMUTABLE;


---
---------------

-----
CREATE or replace FUNCTION stable.rel_dup_properties(
  p_osm_id bigint,
  p_osm_type char,
  p_members_md5_int bigint,
  p_members jsonb,
  p_kname text DEFAULT 'dup_geoms'
) RETURNS JSONb AS $f$
  --  (atualmente 0,1% dos casos pode não estar duplicando relation...)
  SELECT CASE
    WHEN p_kname IS NULL OR x IS NULL THEN x  -- ? x nunca é null
    ELSE jsonb_build_object(p_kname,x)
    END
  FROM (
   -- array de duplicados, eliminando lista de ways e relations já que é duplicada
   SELECT jsonb_agg(x #- '{members,w}' #- '{members,r}') x
   FROM (
    (
      SELECT stable.rel_properties(id) || jsonb_build_object('id','R'||id) x
      FROM planet_osm_rels
      WHERE p_osm_type='r' AND (
      (id != abs(p_osm_id) AND members_md5_int=p_members_md5_int)
      OR
      id = ( -- check case of super-realation of one relation
        SELECT (members->'r'->jsonb_object_1key(members->'r')->>0)::bigint
        FROM planet_osm_rels
        WHERE id=abs(p_osm_id) AND members->>'r_size'='1' AND not(members?'w')
        ) -- /=
      ) -- /AND
    ) -- /select
    UNION
    SELECT stable.way_properties(id)  || jsonb_build_object('id','W'||id) x
    FROM planet_osm_ways
    WHERE
      (p_osm_type='w' AND id != p_osm_id AND nodes_md5_int=p_members_md5_int)
      OR
      id = ( -- check case of realation of one way
        SELECT (members->'w'->jsonb_object_1key(members->'w')->>0)::bigint
        FROM planet_osm_rels
        WHERE p_osm_type='r' AND id=abs(p_osm_id)
          AND members->>'w_size'='1' AND not(members?'r')
      ) -- /=
   ) t1
  ) t2
$f$ LANGUAGE SQL IMMUTABLE;
COMMENT ON FUNCTION stable.rel_dup_properties (bigint, character, bigint, jsonb, text) IS $cmt$
OSM relations with duplicated geometries.  Check all equivalent-relations of @param-p_osm_id.
@returns a members description for duplicates.
@doc-dependences-table(planet_osm_rels,planet_osm_ways)
@doc-dependences-func(stable.rel_properties,stable.way_properties,jsonb_object_1key)
$cmt$;

/* exemplo de uso:
SELECT file_put_contents('lixo.json', (
  SELECT jsonb_pretty(stable.rel_properties(id)
       || stable.rel_dup_properties(id,'r',members_md5_int,members) )
  FROM  planet_osm_rels where id=242467
) ); -- não usar COPY pois gera saida com `\n`

-- Exemplo mais complexo: grava propriedades de todas as cidades:
SELECT t1.name_path, t1.id,
 file_put_contents('final-'||t1.id||'.json', (
  SELECT
    trim((
       jsonb_strip_nulls(stable.rel_properties(r1.id)
       || COALESCE(stable.rel_dup_properties(r1.id,'r',r1.members_md5_int,r1.members),'{}'::jsonb) )
    )::text, 'SP')
  FROM  planet_osm_rels r1 where r1.id=t1.id
 ) ) -- /selct /file
FROM (
 SELECT *, stable.getcity_rels_id(name_path) id  from stable.city_test_names
) t1, LATERAL (
 SELECT * FROM planet_osm_rels r WHERE  r.id=t1.id
) t2;
*/

CREATE or replace FUNCTION stable.rel_properties(
  p_osm_id bigint
) RETURNS JSONb AS $f$
  SELECT tags || jsonb_build_object('members',members)
  || COALESCE(stable.rel_dup_properties(id,'r',members_md5_int,members),'{}'::jsonb)
  FROM planet_osm_rels
  WHERE id = abs(p_osm_id)
$f$ LANGUAGE SQL IMMUTABLE;

CREATE or replace FUNCTION stable.way_properties(
  p_osm_id bigint
) RETURNS JSONb AS $f$
  SELECT tags || jsonb_build_object(
    'nodes',nodes,
    'nodes_md5',LPAD(to_hex(nodes_md5_int),16,'0')
  ) || COALESCE(
    select from rels!
    stable.rel_dup_properties(id,'w',nodes_md5_int,nodes),
    '{}'::jsonb
  )
  FROM planet_osm_ways r
  WHERE id = p_osm_id
$f$ LANGUAGE SQL IMMUTABLE;

CREATE or replace FUNCTION stable.element_properties(
  p_osm_id bigint,
  p_osm_type char default NULL
) RETURNS JSONb AS $wrap$
  SELECT CASE
      WHEN ($2 IS NULL AND $1<0) OR $2='r' THEN stable.rel_properties($1)
      ELSE stable.way_properties($1)
    END
$wrap$ LANGUAGE SQL IMMUTABLE;

CREATE or replace FUNCTION stable.tags_to_csv(
  p_input jsonb,
  p_sep text DEFAULT '; '
) RETURNS text AS $f$
 SELECT array_to_string(array_agg(key||'='||value),p_sep)
 FROM jsonb_each_text($1)
$f$ LANGUAGE SQL IMMUTABLE;

/**
 * Enhances ST_AsGeoJSON() PostGIS function.
 * Use ST_AsGeoJSONb( geom, 6, 1, osm_id::text, stable.element_properties(osm_id) - 'name:' ).
 */
CREATE or replace FUNCTION ST_AsGeoJSONb( -- ST_AsGeoJSON_complete
  p_geom geometry,
  p_decimals int default 6,
  p_options int default 1,  -- 1=better (implicit WGS84) tham 5 (explicit)
  p_id text default null,
  p_properties jsonb default null,
  p_name text default null,
  p_title text default null,
  p_id_as_int boolean default false
) RETURNS JSONb AS $f$
  -- Do ST_AsGeoJSON() adding id, crs, properties, name and title
  SELECT ST_AsGeoJSON(p_geom,p_decimals,p_options)::jsonb
         || CASE
            WHEN p_properties IS NULL OR jsonb_typeof(p_properties)!='object' THEN '{}'::jsonb
            ELSE jsonb_build_object('properties',p_properties)
            END
         || CASE
            WHEN p_id IS NULL THEN '{}'::jsonb
            WHEN p_id_as_int THEN jsonb_build_object('id',p_id::bigint)
            ELSE jsonb_build_object('id',p_id)
            END
         || CASE WHEN p_name IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('name',p_name) END
         || CASE WHEN p_title IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('title',p_title) END
$f$ LANGUAGE SQL IMMUTABLE;


CREATE or replace FUNCTION stable.std_GeoJSONb(
  p_id bigint,
  p_members_md5_int bigint,
  p_members jsonb
) RETURNS JSONb AS $f$
  SELECT ST_AsGeoJSONb(
      (SELECT way FROM planet_osm_polygon WHERE osm_id=-p_id),
      6,
      1,
      'R'||p_id::text,
      jsonb_strip_nulls(stable.rel_properties(p_id) || COALESCE(stable.rel_dup_properties(
        p_id, 'r', p_members_md5_int, p_members), '{}'::jsonb
      ) )
    )
$f$ LANGUAGE SQL IMMUTABLE;


/*
-- readfile, see http://shuber.io/reading-from-the-filesystem-with-postgres/
-- key can be pg_read_file() but no permission
-- ver http://www.postgresonline.com/journal/archives/100-PLPython-Part-2-Control-Flow-and-Returning-Sets.html
-- e https://stackoverflow.com/a/41473308/287948
-- e https://stackoverflow.com/a/48485531/287948
CREATE OR REPLACE FUNCTION readfile (filepath text)
  RETURNS text
AS $$
 import os
 if not os.path.exists(filepath):
  return "file not found"
 return open(filepath).read()
$$ LANGUAGE plpythonu;
*/


CREATE or replace FUNCTION file_get_contents(p_file text) RETURNS text AS $$
   with open(args[0],"r") as content_file:
       content = content_file.read()
   return content
$$ LANGUAGE PLpythonU;

CREATE or replace FUNCTION file_put_contents(
  p_file text,                  -- arg0
  p_content text,               -- arg1
  p_folder text DEFAULT '',     -- arg2
  p_basepath text DEFAULT '/tmp', -- arg4 3
  p_msg text DEFAULT ' (file "%s" saved!) '
) RETURNS text AS $$
  import os
  if args[2].find('/')>0 :
    filepath = args[3] + args[2]
  else:
    filepath = args[3] +'/'+ args[2]
  if not os.path.exists(filepath):
    os.mkdir(filepath)
  file = filepath+'/'+args[0]
  o=open(file,"w")
  o.write(args[1])
  o.close()
  if args[4] and args[4].find('%s')>0 :
    return (args[4] % file)
  else:
    return args[4]
$$ LANGUAGE PLpythonU;

CREATE or replace FUNCTION ST_GeomFromGeoJSON_sanitized( p_j  JSONb, p_srid int DEFAULT 4326) RETURNS geometry AS $f$
  -- do ST_GeomFromGeoJSON()  with correct SRID.  OLD geojson_sanitize().
  -- as https://gis.stackexchange.com/a/60945/7505
  SELECT g FROM (
   SELECT  ST_GeomFromGeoJSON(g::text)
   FROM (
   SELECT CASE
    WHEN p_j IS NULL OR p_j='{}'::JSONb OR jsonb_typeof(p_j)!='object'
        OR NOT(p_j?'type')
        OR  (NOT(p_j?'crs') AND (p_srid<1 OR p_srid>998999) )
        OR p_j->>'type' NOT IN ('Feature', 'FeatureCollection', 'Position', 'Point', 'MultiPoint',
         'LineString', 'MultiLineString', 'Polygon', 'MultiPolygon', 'GeometryCollection')
        THEN NULL
    WHEN NOT(p_j?'crs')  OR 'EPSG0'=p_j->'crs'->'properties'->>'name'
        THEN p_j || ('{"crs":{"type":"name","properties":{"name":"EPSG:'|| p_srid::text ||'"}}}')::jsonb
    ELSE p_j
    END
   ) t2(g)
   WHERE g IS NOT NULL
  ) t(g)
  WHERE ST_IsValid(g)
$f$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION read_geojson(
  -- file_get_geojson
  p_path text,
  p_ext text DEFAULT '.geojson',
  p_basepath text DEFAULT '/opt/gits/city-codes/data/dump_osm/'::text,
  p_srid int DEFAULT 4326
) RETURNS geometry AS $f$
  SELECT CASE WHEN length(s)<30 THEN NULL ELSE ST_GeomFromGeoJSON_sanitized(s::jsonb) END
  FROM  ( SELECT file_get_contents(p_basepath||p_path||p_ext) ) t(s)
$f$ LANGUAGE SQL IMMUTABLE;

-- --

CREATE or replace FUNCTION stable.id_ibge2uf(p_id text) REtURNS text AS $$
  -- A rigor deveria ser construida pelo dataset brcodes... Gambi.
  -- Using official codes of 2018, lookup-table, from IBGE code to UF abbreviation.
  -- for general city-codes use stable.id_ibge2uf(substr(id,1,2))
  SELECT ('{
    "12":"AC", "27":"AL", "13":"AM", "16":"AP", "29":"BA", "23":"CE",
    "53":"DF", "32":"ES", "52":"GO", "21":"MA", "31":"MG", "50":"MS",
    "51":"MT", "15":"PA", "25":"PB", "26":"PE", "22":"PI", "41":"PR",
    "33":"RJ", "24":"RN", "11":"RO", "14":"RR", "43":"RS", "42":"SC",
    "28":"SE", "35":"SP", "17":"TO"
  }'::jsonb)->>$1
$$ language SQL immutable;

-- -- -- -- -- --
-- CEP funcions. To normalize and convert postalCode_ranges to integer-ranges:

CREATE or replace FUNCTION stable.csvranges_to_int4ranges(
  p_range text
) RETURNS int4range[] AS $f$
   SELECT ('{'||
      regexp_replace( translate(regexp_replace($1,'\][;, ]+\[','],[','g'),' -',',') , '\[(\d+),(\d+)\]', '"[\1,\2]"', 'g')
   || '}')::int4range[];
$f$ LANGUAGE SQL IMMUTABLE;

CREATE or replace FUNCTION stable.int4ranges_to_csvranges(
  p_range int4range[]
) RETURNS text AS $f$
   SELECT translate($1::text,',{}"',' ');
$f$ LANGUAGE SQL IMMUTABLE;


CREATE or replace FUNCTION jsonb_strip_nulls_v2(
  -- on  empty returns null
  p_input jsonb
) RETURNS jsonb AS $f$
   SELECT CASE WHEN x='{}'::JSONb THEN NULL ELSE x END
   FROM (SELECT jsonb_strip_nulls($1)) t(x)
$f$ LANGUAGE SQL IMMUTABLE;


-- -- -- -- -- -- -- -- -- -- -- --
-- -- report and mkdump auxiliar lib



/**
 * COPY TO CSV HEADER.
 */
CREATE or replace FUNCTION copy_csv(
  p_filename  text,
  p_query     text,
  p_useheader boolean = true,
  p_root      text    = '/tmp/stable/'
) RETURNS boolean AS $f$
BEGIN
  EXECUTE format(
    'COPY (%s) TO %L CSV %s'
    ,p_query
    ,p_root||p_filename
    ,CASE WHEN p_useheader THEN 'HEADER' ELSE '' END
  );
  RETURN true;
END;
$f$ LANGUAGE plpgsql;


-----
-----

-- NORMALIZACOES


CREATE FUNCTION stable.normalizeterm(
	--
	-- Converts string into standard sequence of lower-case words.
  -- Para uso nas URNs, NAO USAR para normalização de texto em geral TXT.
	--
	text,       		-- 1. input string (many words separed by spaces or punctuation)
	text DEFAULT ' ', 	-- 2. output separator
	int DEFAULT 0,	-- 3. max lenght of the result (system limit). 0=full.
	p_sep2 text DEFAULT ' , ' -- 4. output separator between terms
) RETURNS text AS $f$
  SELECT  substring(
	LOWER(TRIM( regexp_replace(  -- for review: regex(regex()) for ` , , ` remove
		trim(regexp_replace($1,E'[\\n\\r \\+/,;:\\(\\)\\{\\}\\[\\]="\\s ]*[\\+/,;:\\(\\)\\{\\}\\[\\]="]+[\\+/,;:\\(\\)\\{\\}\\[\\]="\\s ]*|[\\s ]+[–\\-][\\s ]+',
				   p_sep2, 'g'),' ,'),   -- s*ps*|s-s
		E'[\\s ;\\|"]+[\\.\'][\\s ;\\|"]+|[\\s ;\\|"]+',    -- s.s|s
		$2,
		'g'
	), $2 )),
  1,
	CASE WHEN $3<=0 OR $3 IS NULL THEN char_length($1) ELSE $3 END
  );
$f$ LANGUAGE SQL IMMUTABLE;


CREATE FUNCTION stable.normalizeterm2(
	text,
	boolean DEFAULT true  -- cut
) RETURNS text AS $f$
   SELECT (  stable.normalizeterm(
    CASE WHEN $2 THEN substring($1 from '^[^\(\)\/;]+' ) ELSE $1 END,
	  ' ',
	  255,
    ' / '
   ));
$f$ LANGUAGE SQL IMMUTABLE;

CREATE or replace FUNCTION stable.name2lex(
	-- usar unaccent(x) e [^\w], antes convertendo D'Xx para Xx  e preservando data-iso com _x_
  p_name text
  ,p_normalize boolean DEFAULT true
  ,p_cut boolean DEFAULT true
	,p_flag boolean DEFAULT true -- unaccent flag
) RETURNS text AS $f$
	 SELECT CASE WHEN p_flag THEN urn ELSE urn END
	 FROM (
	   SELECT trim(replace(
		   regexp_replace(
			     CASE
			      WHEN p_normalize AND p_flag THEN stable.normalizeterm2(unaccent($1),p_cut)
			      WHEN p_normalize THEN stable.normalizeterm2($1,p_cut)
			      ELSE $1
			     END,
			     E' d[aeo] | d[oa]s | com | para |^d[aeo] | / .+| [aeo]s | [aeo] |[\-\' ]',
			     '.',
			     'g'
			   ),
			   '..',
		     '.'
		    ),'.')
		) t(urn)
$f$ LANGUAGE SQL IMMUTABLE;
