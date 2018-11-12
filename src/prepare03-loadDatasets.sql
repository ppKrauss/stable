--
-- Import datasets of Brazilian codes by streaming instaled to copy.
--

--
-- Prepare brcodes_city:
DROP FOREIGN TABLE IF EXISTS tmpcsv_br_city_codes CASCADE;
CREATE FOREIGN TABLE tmpcsv_br_city_codes (
	name text,
	state text,
	"wdId" text,
	"idIBGE" int,
	"lexLabel" text,
	creation integer,
	extinction integer,
	"postalCode_ranges" text,
	ddd integer,
	abbrev3 text,
	notes text
) SERVER files OPTIONS (
	filename '/tmp/br_city_codes.csv',
	format 'csv',
	header 'true'
);
CREATE TABLE brcodes_city AS
  SELECT
		"idIBGE" ibge_id,
		substr("wdId",2)::bigint wikidata_id,
		state uf,
		name,
		"lexLabel" lexlabel,
		creation,
		stable.csvranges_to_int4ranges("postalCode_ranges") cep_range,
		ddd,
		abbrev3
	FROM  tmpcsv_br_city_codes
	WHERE extinction IS NULL OR extinction=0
;
CREATE UNIQUE INDEX idx1_brcodes_city ON brcodes_city(ibge_id);
CREATE UNIQUE INDEX idx2_brcodes_city ON brcodes_city(wikidata_id);
CREATE UNIQUE INDEX idx4_brcodes_city ON brcodes_city(uf,lexlabel);
CREATE UNIQUE INDEX idx4_brcodes_city ON brcodes_city(uf,abbrev3);
CREATE UNIQUE INDEX idx3_brcodes_city ON brcodes_city(uf,name);
CREATE UNIQUE INDEX idx5_brcodes_city ON brcodes_city(cep_range);

DROP FOREIGN TABLE tmpcsv_ibge_municipios_areas CASCADE;
CREATE FOREIGN TABLE tmpcsv_ibge_municipios_areas (
	"qID" int,  -- gid
	"CD_GCUF" int, -- ibge_id_uf
	"NM_UF" text, -- nome da UF
	"NM_UF_SIGLA" text, -- UF
	"CD_GCMUN" text, -- ibge_id do municipio
	"NM_MUN_2017" text, -- nome
	"AR_MUN_2017" text, -- float
	mult1000 bigint -- reverter float
) SERVER files OPTIONS (
	filename '/tmp/AR_BR_RG_UF_MES_MIC_MUN_2017.csv',
	format 'csv',
	header 'true'
);
CREATE TABLE ibge_lim_munic_2017_area AS
  SELECT "CD_GCMUN" geocodigo, "NM_UF_SIGLA" uf, "NM_MUN_2017" nome,
         mult1000::float/1000.0 area
	FROM tmpcsv_ibge_municipios_areas
;

CREATE VIEW vw_ibge_lim_munic_2017_calckm2 AS
  SELECT *, 100.0*abs(a_km2-geom_km2)/a_km2 as diffkm2_perc
  FROM (
     SELECT a.geocodigo, g.nome, a.area a_km2, st_area(geom,true)/1000000.0 geom_km2
     FROM ibge_lim_munic_2017_area a INNER JOIN ibge_lim_munic_2017 g
       ON a.geocodigo=g.geocodigo AND a.geocodigo not IN ('4300001','4300002')
  ) t;

--

DROP FOREIGN TABLE tmpcsv_br_city_codes CASCADE;
--
-- Prepare brcodes_state:
DROP FOREIGN TABLE IF EXISTS tmpcsv_br_state_codes CASCADE;
CREATE FOREIGN TABLE tmpcsv_br_state_codes (
	subdivision text,
	region text,
	name_prefix text,
	name text,
	id integer,
	"idIBGE" text,
	"wdId" text,
	"lexLabel" text,
	creation integer,
	extinction integer,
	category text,
	"timeZone" text,
	"utcOffset" integer,
	"utcOffset_DST" integer,
	"postalCode_ranges" text,
	km2 int,
	borders text,
	centroid_geohash text,
	utm_zones text,
	bounds_geohash text,
	bounds_lat text,
	bounds_long text,
	notes text
) SERVER files OPTIONS (
	filename '/tmp/br-state-codes.csv', -- windows transforma '-' em '_'?
	format 'csv',
	header 'true'
);
CREATE TABLE brcodes_state AS
  SELECT
		subdivision uf, name, region, name_prefix, id,
		"idIBGE" ibge_id,
		substr("wdId",2)::bigint wikidata_id,
		"lexLabel" lexlabel,
		creation,
		stable.csvranges_to_int4ranges("postalCode_ranges") cep_range,
		category,
		"timeZone" timezone,
		"utcOffset" utc_Offset,
		"utcOffset_DST" utc_Offset_DST
	FROM tmpcsv_br_state_codes
	WHERE extinction IS NULL OR extinction=0
;
CREATE UNIQUE INDEX idx1_brcodes_state ON brcodes_state(ibge_id);
CREATE UNIQUE INDEX idx2_brcodes_state ON brcodes_state(wikidata_id);
CREATE UNIQUE INDEX idx3_brcodes_state ON brcodes_state(uf);
CREATE UNIQUE INDEX idx4_brcodes_state ON brcodes_state(name);
DROP FOREIGN TABLE tmpcsv_br_state_codes CASCADE;

--
-- Prepare brcodes_region:
DROP FOREIGN TABLE IF EXISTS tmpcsv_br_region_codes CASCADE;
CREATE FOREIGN TABLE tmpcsv_br_region_codes (
	region text,
	"wdId" text,
	name text,
	fullname text,
	creation integer,
	extinction integer,
	"postalCode_ranges" text,
	notes text
) SERVER files OPTIONS (
	filename '/tmp/br-region-codes.csv',
	format 'csv',
	header 'true'
);
CREATE TABLE brcodes_region AS
  SELECT
		region,
		substr("wdId",2)::bigint wikidata_id,
		name, fullname, creation
	FROM  tmpcsv_br_region_codes
	WHERE extinction IS NULL OR extinction=0
;
CREATE UNIQUE INDEX idx2_brcodes_region ON brcodes_region(wikidata_id);
DROP FOREIGN TABLE tmpcsv_br_region_codes CASCADE;


CREATE VIEW vw_brcodes_state AS
	SELECT s.*, r.name region_name, r.fullname region_fullname
	FROM brcodes_state s INNER JOIN brcodes_region r
	ON r.region=s.region
;
CREATE VIEW vw_brcodes_city AS
  SELECT c.*, s.name uf_name, s.name_prefix uf_name_prefix,
	       s.ibge_id uf_ibge_id, s.wikidata_id uf_wikidata_id,
				 s.lexlabel uf_lexlabel,
	       s.region, s.region_name, s.region_fullname
	FROM brcodes_city c INNER JOIN vw_brcodes_state s
	  ON c.uf=s.uf
;

CREATE VIEW vw_brcodes_city_filepath AS
  SELECT ibge_id, uf, lexlabel, wikidata_id
	       , uf || '/' || stable.lexname_to_path(lexlabel) folder_name
				 , name
  FROM vw_brcodes_city
;
