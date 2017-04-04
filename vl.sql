

-------------------
-- PREP DATABASE --
-------------------

-- preparing database for pgrouting --
CREATE DATABASE network_2;
\connect network_2;
CREATE SCHEMA postgis;
ALTER DATABASE network_2 SET search_path=public,postgis;
\connect network_2;
CREATE EXTENSION postgis SCHEMA postgis;
CREATE EXTENSION pgrouting SCHEMA postgis;
CREATE EXTENSION pgrouting SCHEMA postgis CASCADE;
-- check version
SELECT * FROM pgr_version();



-------------------
-- PREP INDATA ----
-------------------

-- VL (Översiktskartan)
----------
-- add source and target that will store nodes -
ALTER TABLE vl ADD COLUMN "source" integer;
ALTER TABLE vl ADD COLUMN "target" integer;
SELECT pgr_createTopology('vl', 10, 'geom', 'gid');
-- index source and targets
CREATE INDEX ix_source_vl ON vl(source);
CREATE INDEX ix_target_vl ON vl(target);
-- add lengths which will be used for costing
ALTER TABLE vl ADD COLUMN length float8;
UPDATE vl SET length = ST_Length(geom);


-- NVDB
--------
-- create subset
SELECT min(v.gid) as gid, v.hthast, an.lansnamn, v.geom, count(rlid) AS count_rlid
	INTO nvdb_subset
	FROM nvdb_work AS v, laensindelning AS an
	WHERE ST_intersects(v.geom, an.geom) AND an.lan_kod = '01' -- 01 = Stockholms län
	GROUP BY an.lansnamn, v.hthast, v.geom, v.rlid;
-- remove Z values from geometry
ALTER TABLE nvdb_subset
ALTER COLUMN geom TYPE geometry(LineString,3006) USING ST_Force2D(geom);
-- create noded network (splits lines a nodes)
SELECT pgr_nodenetwork('nvdb_subset', 2, 'gid', 'geom');
-- join in attribute data from the pre-noded network
SELECT n.id, n.source, n.target, n.geom, o.hthast, n.old_id
	INTO nvdb_subset_merge
	FROM nvdb_subset_noded AS n
	LEFT JOIN nvdb_subset AS o ON n.old_id = o.gid;
-- calculate length
ALTER TABLE nvdb_subset_merge ADD COLUMN length float8;
UPDATE nvdb_subset_merge SET length = ST_Length(geom);
-- calculate travel time based on speed limit
ALTER TABLE nvdb_subset_merge ADD COLUMN time_sec float8;
UPDATE nvdb_subset_merge
	SET time_sec = length / (hthast / 3.6);
-- create network graph
SELECT pgr_createTopology('nvdb_subset_merge', 2, 'geom', 'id');
-- index
CREATE INDEX ix_source_subset ON nvdb_subset_merge(source);
CREATE INDEX ix_target_subset ON nvdb_subset_merge(target);



-------------------
-- ANALYSIS VL ----
-------------------

-- calculate driving distance from each poi
SELECT o.kategori, o.namn1 AS namn, dd.from_v, dd.node, dd.agg_cost::int, n.the_geom As geom
	INTO vl_dd_akutsjukhus
	FROM pgr_drivingDistance(
		'SELECT gid As id, source As target, target As source,
			length AS cost, length AS reverse_cost
			FROM vl',
		ARRAY(SELECT v.id
			FROM bs
			,LATERAL (SELECT id FROM vl_vertices_pgr AS n
			WHERE bs.kategori = 'Akutsjukhus'
			ORDER BY bs.geom <-> n.the_geom LIMIT 1) AS v
			)
		, 400000, true, equicost := true
	) AS dd
	INNER JOIN vl_vertices_pgr As n ON dd.node = n.id
    LEFT JOIN (SELECT kategori, namn1, id
                FROM bs
                ,LATERAL (SELECT id FROM vl_vertices_pgr AS n
                	WHERE bs.kategori = 'Akutsjukhus'
                	ORDER BY bs.geom <-> n.the_geom LIMIT 1) AS k ) AS o on dd.from_v = o.id;

-- group driving distance table by start node (poi) and make an array with all target nodes
SELECT from_v AS start_node, namn, kategori, array_agg(node) AS target_node_array
	INTO vl_dd_akutsjukhus_summary
	FROM vl_dd_akutsjukhus
	GROUP BY start_node, namn, kategori;

-- calculate shortest path from all of the nodes to the closest poi
	SELECT start_node, namn, dd.kategori, edge, node, geom, agg_cost
	INTO vl_routes_akutsjukhus
	FROM vl_dd_akutsjukhus_summary AS dd,
	LATERAL
		pgr_dijkstra(
			'SELECT gid AS id, source, target, length AS cost FROM vl',
			dd.start_node,
			dd.target_node_array,
			FALSE
		) AS d
		LEFT JOIN vl ON d.edge = vl.gid;

	-- summarise the number of uses of every edge
	SELECT start_node, namn, count(edge), edge, node, geom, agg_cost
	INTO vl_routes_n_uses
	FROM vl_routes_akutsjukhus
	GROUP BY start_node, namn, edge, node, geom, agg_cost;


-- prep for wrangling in R below, all of this could have been woven in above, but I'm short on time and don't want to mess it up.
-- get which dd.nodes are in which county
SELECT vl.kategori, vl.namn, vl.from_v, vl.node, vl.agg_cost, l.lansnamn AS lansnamn_node, l.lanskod AS lanskod_node,  vl.geom
INTO vl_dd_akutsjukhus_counties
FROM vl_dd_akutsjukhus AS vl, laensindelning AS l
WHERE ST_within(vl.geom, l.geom);
-- get which routes are in which county. nopes not necessary + time consuming. the one above can be joined to n uses
-- SELECT r.kategori, r.namn, r.start_node, r.edge, r.agg_cost, l.lansnamn AS lansnamn_edge, l.lanskod AS lanskod_edge,  r.geom
-- INTO vl_routes_akutsjukhus_counties_2
-- FROM vl_routes_akutsjukhus AS r, laensindelning AS l
-- WHERE ST_intersects(r.geom, l.geom);
-- get which sjukhus belongs to which county
SELECT bs.namn1 AS namn, lansnamn AS lansnamn_sjukhus, lanskod AS lanskod_sjukhus, bs.geom
INTO test2
FROM bs, laensindelning
WHERE ST_intersects(bs.geom, laensindelning.geom) AND bs.kategori = 'Akutsjukhus';


-------------------
-- NVDB -----------
-------------------
-- ej fixad

--berakna driving time for 
SELECT dd.*, n.the_geom As geom
	INTO dt_anga
	FROM pgr_drivingDistance(
		'SELECT id, target, source,
			time_sec AS cost
			FROM nvdb_gotland_noded_join',
		ARRAY(SELECT v.id
	FROM my_pois AS h
		,LATERAL (SELECT id FROM nvdb_gotland_noded_join_vertices_pgr AS n
			ORDER BY h.geom <-> n.the_geom LIMIT 1) AS v
			)
		, 5000, false, equicost := true
		) AS dd
		INNER JOIN nvdb_gotland_noded_join_vertices_pgr As n ON dd.node = n.id;

-- gruppera dt_ tabellen efter startnod och skapa en array med alla tillnoder
SELECT from_v AS start_node, array_agg(node) AS target_node_array
	INTO dt_anga_summary
	FROM dt_anga
	GROUP BY start_node;

SELECT start_node, edge, geom, agg_cost
INTO dt_anga_routes
FROM dt_anga_summary AS dd,
LATERAL
	pgr_dijkstra(
		'SELECT id, source, target, time_sec AS cost FROM nvdb_gotland_noded_join',
		dd.start_node,
		dd.target_node_array,
		FALSE
	) AS d
	LEFT JOIN nvdb_gotland_noded_join AS v ON d.edge = v.id;

SELECT start_node, count(edge), agg_cost, geom
INTO dt_anga_n_uses
FROM dt_anga_routes
GROUP BY start_node, geom, agg_cost;