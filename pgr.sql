----QUERY 1, NOTE THAT THIS WILL TAKE SEVERAL MINUTES TO RUN, EXAMPLE ONLY, TO COMPARE WITH QUERY 1 BBOX
SELECT * FROM pgr_dijkstra('SELECT id, source, target, cost, reverse_cost FROM tfn.edge_table',
                           ARRAY(SELECT source FROM tfn.edge_table where id = 1101252773),
						   ARRAY(SELECT source FROM tfn.edge_table where id = 1107955243));

----QUERY 1 BBOX, THIS CREATES A BBOX AND FILTERS THE EDGE TABLE BEFORE RUNNING THE ROUTE
----THE PGROUTING FUNCTIONS CAN'T RUN FROM TEMPORARY TABLES, SO THE EDGES HAVE TO BE PUT IN A NEW TABLE
DROP TABLE IF EXISTS tfn.test_bbox;
CREATE TABLE tfn.test_bbox AS
--First get the start link geometry
WITH start AS (SELECT geometry FROM tfn.edge_table WHERE id = 1101252773),
--Then get the end link geometry
	  dest AS (SELECT geometry FROM tfn.edge_table WHERE id = 1107955243),
--Union the geometry to make a single featur
     bbox1 AS (SELECT geometry from start union SELECT geometry from dest),
--generate the box around those features and buffer it to make sure enough extra network is read in
	 bbox2 AS (SELECT st_buffer(st_setsrid(st_envelope(st_extent(geometry)),27700),200) as geom from bbox1),
--filter the edge table using this bounding box 
	route_bbox AS (SELECT b.* from bbox2 a, tfn.edge_table b where st_dwithin(a.geom, b.geometry, 0))
SELECT * from route_bbox;

SELECT * FROM pgr_dijkstra('SELECT id, source, target, cost, reverse_cost FROM tfn.test_bbox',
                           ARRAY(SELECT source FROM tfn.test_bbox where id = 1101252773),
						   ARRAY(SELECT source FROM tfn.test_bbox where id = 1107955243));

----QUERY 1 VISUALS
DROP TABLE IF EXISTS tfn.test_route;
CREATE TABLE tfn.test_route AS
SELECT ST_Union(geometry) AS route
  FROM pgr_dijkstra(
  'SELECT id, source, target, cost, reverse_cost FROM tfn.test_bbox',
  ARRAY(SELECT source FROM tfn.test_bbox where id = 1101252773),
  ARRAY(SELECT source FROM tfn.test_bbox where id = 1107955243)
   ) AS di
   JOIN tfn.test_bbox AS pt
   ON di.edge = pt.id;

----QUERY 1 TIDY
DROP TABLE IF EXISTS tfn.test_points;
CREATE TABLE tfn.test_points (
	id		int,
	wkt		text
);

INSERT INTO tfn.test_points SELECT 1, 'POINT(504597.90124799754 429660.1030429567)';
INSERT INTO tfn.test_points SELECT 2, 'POINT(504193.4286222651 429680.9538629675)';

DROP TABLE IF EXISTS tfn.test_points_geom;
CREATE TABLE tfn.test_points_geom AS SELECT id, st_geomfromtext(wkt, 27700) as geom
  FROM tfn.test_points;

DROP TABLE IF EXISTS tfn.test_route_tidy1;
CREATE TABLE tfn.test_route_tidy1 AS
SELECT b.source, b.target, b.id, 
--snapping the point to the nearest line sometimes doesn't quite intersect, by a very very tiny amount,this accounts for that
       st_lineextend(st_makeline(a.geom, st_lineinterpolatepoint(b.geometry, st_linelocatepoint(b.geometry,a.geom))),0.1) as geom
  FROM tfn.test_points_geom a, tfn.edge_table b
 WHERE a.id = 1                             --the start point id
   AND st_dwithin(a.geom,b.geometry,100)    --to account for situations where the point might be far away from the nearest link
   AND b.highway not in ('footway')         --an example of restricting certain links from where to start from
   AND b.name is not null                   --to only use named roads
 ORDER BY a.geom <-> b.geometry LIMIT 1;

DROP TABLE IF EXISTS tfn.test_route_tidy2;
CREATE TABLE tfn.test_route_tidy2 AS
SELECT a.source, a.target, a.id, st_distance(b.geometry, a.geom) AS line_dist,
       st_startpoint(b.geometry) AS startpos,
	   st_endpoint(b.geometry) AS endpos,
       (st_dump(st_split(b.geometry, a.geom))).geom AS geom,
       st_length(
	      st_intersection(
	         st_buffer(a.geom,1,'side=left'),
		     (st_dump(st_split(b.geometry, a.geom))).geom)) AS split_len
FROM tfn.test_route_tidy1 a, tfn.edge_table b
WHERE a.id = b.id;

ALTER TABLE tfn.test_route_tidy2 ADD COLUMN start_dist float;
ALTER TABLE tfn.test_route_tidy2 ADD COLUMN end_dist float;
ALTER TABLE tfn.test_route_tidy2 ADD COLUMN source_to_use int;
UPDATE tfn.test_route_tidy2 SET start_dist = st_distance(startpos,geom);
UPDATE tfn.test_route_tidy2 SET end_dist = st_distance(endpos,geom);
UPDATE tfn.test_route_tidy2 SET source_to_use = source WHERE line_dist = 0 AND start_dist = 0 AND split_len > 0;
UPDATE tfn.test_route_tidy2 SET source_to_use = target WHERE line_dist = 0 AND end_dist = 0 AND split_len > 0;

DROP TABLE IF EXISTS tfn.test_route_tidy3;
CREATE TABLE tfn.test_route_tidy3 AS
SELECT b.source, b.target, b.id, 
       st_lineextend(st_makeline(a.geom, st_lineinterpolatepoint(b.geometry, st_linelocatepoint(b.geometry,a.geom))),0.1) AS geom
  FROM tfn.test_points_geom a, tfn.edge_table b
 WHERE a.id = 2
   AND st_dwithin(a.geom,b.geometry,100)
   AND b.highway NOT IN ('footway')
   AND b.name IS NOT NULL
 ORDER BY a.geom <-> b.geometry LIMIT 1;

DROP TABLE IF EXISTS tfn.test_route_tidy4;
CREATE TABLE tfn.test_route_tidy4 AS
SELECT a.source, a.target, a.id, st_distance(b.geometry, a.geom) AS line_dist,
       st_startpoint(b.geometry) AS startpos,
	   st_endpoint(b.geometry) AS endpos,
       (st_dump(st_split(b.geometry, a.geom))).geom AS geom,
       st_length(
          st_intersection(
	         st_buffer(a.geom,1,'side=right'),
		     (st_dump(st_split(b.geometry, a.geom))).geom)) AS split_len
FROM tfn.test_route_tidy3 a, tfn.edge_table b
where a.id = b.id;

ALTER TABLE tfn.test_route_tidy4 ADD COLUMN start_dist float;
ALTER TABLE tfn.test_route_tidy4 ADD COLUMN end_dist float;
ALTER TABLE tfn.test_route_tidy4 ADD COLUMN source_to_use int;
UPDATE tfn.test_route_tidy4 SET start_dist = st_distance(startpos,geom);
UPDATE tfn.test_route_tidy4 SET end_dist = st_distance(endpos,geom);
UPDATE tfn.test_route_tidy4 SET source_to_use = source WHERE line_dist = 0 AND start_dist = 0 AND split_len > 0;
UPDATE tfn.test_route_tidy4 SET source_to_use = target WHERE line_dist = 0 AND end_dist = 0 AND split_len > 0;

DROP TABLE IF EXISTS tfn.test_bbox;
CREATE TABLE tfn.test_bbox AS
--First get the start link geometry
WITH start AS (SELECT source_to_use, geom FROM tfn.test_route_tidy2 WHERE source_to_use IS NOT NULL),
--Then get the end link geometry
	  dest AS (SELECT source_to_use, geom FROM tfn.test_route_tidy4 WHERE source_to_use IS NOT NULL),
--Union the geometry to make a single feature
     bbox1 AS (SELECT geom FROM start UNION SELECT geom FROM dest),
--generate the box around those features and buffer it to make sure enough extra network is read in
	 bbox2 AS (SELECT st_buffer(st_setsrid(st_envelope(st_extent(geom)),27700),200) AS geom from bbox1),
--filter the edge table using this bounding box 
	route_bbox AS (SELECT b.* FROM bbox2 a, tfn.edge_table b WHERE st_dwithin(a.geom, b.geometry, 0))
SELECT * FROM route_bbox;

DROP TABLE IF EXISTS tfn.route_check;
CREATE TABLE tfn.route_check AS
SELECT ST_Union(geometry) AS route, array_agg(pt.id) AS id_list
  FROM pgr_dijkstra(
  'SELECT id, source, target, cost, reverse_cost FROM tfn.test_bbox',
  ARRAY(SELECT source_to_use FROM tfn.test_route_tidy2 WHERE source_to_use IS NOT NULL),
  ARRAY(SELECT source_to_use FROM tfn.test_route_tidy4 WHERE source_to_use IS NOT NULL)) AS di
  JOIN tfn.test_bbox AS pt
    ON di.edge = pt.id;

----QUERY 1 MERGE
DROP TABLE IF EXISTS tfn.final_route;
CREATE TABLE tfn.final_route AS
  WITH step1 AS (SELECT st_linemerge(route) AS geom from tfn.route_check
		          UNION
		         SELECT geom FROM tfn.test_route_tidy2 WHERE source_to_use IS NOT NULL
		          UNION
		         SELECT geom FROM tfn.test_route_tidy4 WHERE source_to_use IS NOT NULL),
       step2 AS (SELECT st_linemerge(st_collect(geom)) AS geom FROM step1),
	   step3 AS (SELECT st_startpoint(geom) AS startpos, st_endpoint(geom) AS endpos from step2),
	   step4 AS (SELECT st_distance(a.geom, b.startpos) AS startdist,
		                st_distance(a.geom, b.endpos) AS enddist
		           FROM tfn.test_route_tidy2 a, step3 b
		          WHERE a.source_to_use IS NOT NULL),
	   step5 AS (SELECT CASE WHEN a.enddist < a.startdist THEN st_reverse(b.geom)
	                    ELSE b.geom
			            END as geom
		           FROM step4 a, step2 b),
	   step6 AS (SELECT array_append(c.id_list, a.id) AS id_list
		           FROM tfn.test_route_tidy1 a, tfn.route_check c),
	   step7 AS (SELECT array_append(c.id_list, a.id) AS id_list
		           FROM tfn.test_route_tidy3 a, step6 c)
SELECT 'test' AS route, 1 AS id, 1 AS source, 2 AS target, a.geom, b.id_list
FROM step5 a, step7 b;

----QUERY 2 ISOCHRONES
SELECT * FROM pgr_drivingDistance('
    SELECT a.id,
	       a.source::int4 AS source,
	       a.target::int4 AS target,
           a.cost::float8 AS cost,
		   a.reverse_cost::float8 AS reverse_cost
	  FROM tfn.edge_table a, tfn.test_points_geom b
	 WHERE b.id = 1
	   AND st_dwithin(a.geometry,b.geom,2000)'::text,
	 array[504966711],
	 1200,
	 false,
	 true);

SELECT * FROM pgr_drivingDistance('
    SELECT a.id,
	       a.source::int4 AS source,
	       a.target::int4 AS target,
           a.cost::float8 AS cost,
		   a.reverse_cost::float8 AS reverse_cost
	  FROM tfn.edge_table a, tfn.test_points_geom b
	 WHERE b.id = 1
	   AND st_dwithin(a.geometry,b.geom,16000)'::text,
	 array[504966711],
	 15000,
	 false,
	 true);

DROP TABLE IF EXISTS tfn.test_nodes;
CREATE TABLE tfn.test_nodes AS
SELECT * FROM tfn.node_table_lsoa a JOIN (
SELECT * FROM pgr_drivingDistance('
    SELECT a.id,
	       a.source::int4 AS source,
	       a.target::int4 AS target,
           a.cost::float8 AS cost,
		   a.reverse_cost::float8 AS reverse_cost
	  FROM tfn.edge_table a, tfn.test_points_geom b
	 WHERE b.id = 1
	   AND st_dwithin(a.geometry,b.geom,2000)'::text,
	 array[504966711],
	 1200,
	 false,
	 true)) as route on a.nodeid = route.node;

DROP TABLE IF EXISTS tfn.test_nodes_200m;
CREATE TABLE tfn.test_nodes_200m AS
SELECT St_ConcaveHUll(St_collect(geom), 0.5) AS geom
FROM tfn.test_nodes WHERE agg_cost <= 200;

DROP TABLE IF EXISTS tfn.test_nodes_400m;
CREATE TABLE tfn.test_nodes_400m AS
SELECT St_ConcaveHUll(St_collect(geom), 0.5) AS geom
FROM tfn.test_nodes WHERE agg_cost <= 400;

DROP TABLE IF EXISTS tfn.test_nodes_600m;
CREATE TABLE tfn.test_nodes_600m AS
SELECT St_ConcaveHUll(St_collect(geom), 0.5) AS geom
FROM tfn.test_nodes WHERE agg_cost <= 600;