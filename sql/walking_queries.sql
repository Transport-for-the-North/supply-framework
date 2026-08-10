-- Create connection lines
DROP TABLE IF EXISTS connection_lines;
CREATE TABLE connection_lines AS
SELECT
  c.start_centroid,
  c.target_centroid,
  ST_MakeLine(p1.geom, p2.geom) AS geom,
  CASE
    WHEN agg_cost < 5000 THEN '0-5 km'
    WHEN agg_cost < 10000 THEN '5-10 km'
    WHEN agg_cost < 15000 THEN '10-15 km'
    WHEN agg_cost < 20000 THEN '15-20 km'
    WHEN agg_cost < 25000 THEN '20-25 km'
    ELSE '25+ km'
  END AS dist_band
FROM tfn.walking_isochrones_centroids c
JOIN tfn.node_centroids p1 ON c.start_centroid = p1.centroid_id
JOIN tfn.node_centroids p2 ON c.target_centroid = p2.centroid_id



-- DRIVING DIST SINGLE
DROP TABLE IF EXISTS tfn.test_nodes_pg5;
CREATE TABLE tfn.test_nodes_pg5 AS
SELECT
	n.centroid_id,
	n.node_id,
	route.node,
	route.seq,
	route.depth,
	route.start_vid,
	route.pred,
	route.edge,
	route.cost,
	route.agg_cost
FROM tfn.node_centroids5 n
CROSS JOIN LATERAL pgr_drivingDistance(
	format('
	SELECT 
		a.id,
		a.source::int4 AS source,
		a.target::int4 AS target,
		a.cost::float8 AS cost,
		a.reverse_cost::float8 AS reverse_cost
	FROM tfn.edge_table a
	WHERE st_dwithin(
		a.geometry,
		st_geomfromtext(''%s'', %s),
		30000
	)',
	ST_AsText(n.geom),
	ST_SRID(n.geom)
	)::text,
	array[n.node_id],
	20000,
	false,
	true) as route;

				
CREATE TABLE tfn.test_nodes_select_pg5 AS
SELECT * FROM tfn.test_nodes_pg5 a
INNER JOIN (
	SELECT node_id as node_id_b, geom FROM tfn.node_centroids_v1
) b
ON a.node = b.node_id_b;



WITH iso_nodes AS (
SELECT * FROM pgr_drivingDistance('
	SELECT a.id,
		a.source::int4 AS source,
		a.target::int4 AS target,
		a.cost::float8 AS cost,
		a.reverse_cost::float8 AS reverse_cost
	FROM tfn.edge_table a, tfn.node_centroids5 b
	WHERE b.node_id = 603346119
	AND st_dwithin(a.geometry,b.geom,30000)'::text,
	array[603346119],
	20000,
	false,
	true)
)
SELECT * FROM iso_nodes a
INNER JOIN (
	SELECT * FROM tfn.node_centroids_v1
	) b
ON a.node = b.node_id;

-- NODE CENTROIDS
CREATE TABLE tfn.node_centroids_v1 AS
SELECT
    c.zone_id AS centroid_id,
    n.nodeid AS node_id,
    n.dist,
    n.geom
FROM public.centroids c
CROSS JOIN LATERAL (
    SELECT n.nodeid, n.geom, n.geom <-> c.geometry AS dist
    FROM tfn.node_table AS n
    WHERE EXISTS (
        SELECT 1
        FROM tfn.edge_table e
        WHERE e.source = n.nodeid
           OR e.target = n.nodeid
    )
    ORDER BY dist
    LIMIT 1
) n;