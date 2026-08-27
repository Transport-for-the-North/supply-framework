-- Query to create connection lines to visualise the cost matrix
-- It will make lines connecting start and target centroids with distance bands based on the cost between them.
-- This can be visualised in QGIS by changing the thickness of the lines based on the distance bands.

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