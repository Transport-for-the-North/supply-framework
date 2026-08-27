--ogr2ogr -f PostgreSQL -progress -gt 65000 -a_srs EPSG:4326 -lco SCHEMA=tfn -lco GEOMETRY_NAME=geometry PG:"dbname=postgres host=localhost port=5433 user=postgres password=postgres" OSMulti-modalRoutingNetwork.gpkg
--CREATE INDEXES ON THE TABLES CREATED FROM THIS IMPORT
CREATE INDEX mrn_ntwk_turnrestriction_wayid_idx ON tfn.mrn_ntwk_transportlink USING btree (wayid);
CREATE INDEX mrn_ntwk_turnrestriction_nodeid_idx ON tfn.mrn_ntwk_transportnode USING btree (nodeid);
CREATE INDEX mrn_ntwk_turnrestriction_relationid_idx ON tfn.mrn_ntwk_turnrestriction USING btree (relationid);

--BUILD THE EDGE TABLE FROM MRN THAT WILL BE USED FOR THE FULL DETAIL ROUTING AND CREATING THE SIMPLIFIED NETWORK
drop table tfn.edge_table;
CREATE TABLE tfn.edge_table AS
SELECT wayid AS id, name, foot, highway, railway, rail, ferry, toll, junction, route, ford, bridge, tunnel, service, oneway,
  ST_Length(geometry::geography) AS length, (STRING_TO_ARRAY(nodes, ',')::int[])[1] AS source, -- converts the nodes string to an array and extracts the first index item
  (STRING_TO_ARRAY(nodes, ',')::int[])[array_upper((STRING_TO_ARRAY(nodes, ',')::int[]), 1)] AS target, -- converts the nodes string to an array and extracts the last index item
  CASE
    WHEN oneway = '-1' THEN -1
    ELSE ST_Length(geometry::geography) -- returns the geometry length in metres
  END AS cost,
  CASE
    WHEN oneway = 'yes' THEN -1
    ELSE ST_Length(geometry::geography) -- returns the geometry length in metres
  END AS reverse_cost,
  st_transform(geometry,27700) as geometry
FROM tfn.mrn_ntwk_transportlink;

CREATE UNIQUE INDEX edge_table_id_idx ON tfn.edge_table (id);
CREATE INDEX edge_table_source_idx ON tfn.edge_table (source);
CREATE INDEX edge_table_target_idx ON tfn.edge_table (target);
CREATE INDEX edge_table_geometry_idx ON tfn.edge_table USING gist (geometry);

--BUILD THE NODE TABLE FROM MRN AND GIVE IT A SPATIAL INDEX
drop table tfn.node_table;
create table tfn.node_table AS
select nodeid, st_transform(geometry,27700) as geom
from tfn.mrn_ntwk_transportnode;

create index node_table_idx on tfn.node_table using GIST (geom);

--SNAP THE NODES TO THE LSOA TABLE TO JOIN THE LSOA CODE
drop table tfn.node_table_lsoa;
create table tfn.node_table_lsoa as
select a.nodeid, a.geom, b.lsoa21cd
from tfn.node_table a, tfn.lsoa b
where st_dwithin(a.geom,b.geom,0);

create index node_table_lsoa_idx on tfn.node_table_lsoa using GIST (geom);

--SNAP THE EDGE TABLE LINKS TO THE LSOA TABLE
drop table tfn.edge_table_lsoa;
create table tfn.edge_table_lsoa as
select a.id, a.geometry, st_length(st_intersection(a.geometry,b.geom)) as segment_length, b.lsoa21nm
from tfn.edge_table a, tfn.lsoa b
where st_dwithin(a.geometry,b.geom,0);

alter table tfn.edge_table_lsoa add column rowid serial;
create index edge_table_lsoa_id on tfn.edge_table_lsoa (id);
create index edge_table_lsoa_rowid on tfn.edge_table_lsoa (rowid);

--WHERE EDGE LINKS CROSS MULTIPLE LSOA'S, FIND WHICH LSOA HAS THE LONGEST STRETCH
drop table tfn.edge_table_lsoa2;
create table tfn.edge_table_lsoa2 as
select id, max(segment_length) as segment_length
from tfn.edge_table_lsoa group by id;

create index edge_table_lsoa2_id on tfn.edge_table_lsoa2 (id);

create table tfn.edge_table_lsoa3 as
select a.id, a.rowid, a.geometry, a.lsoa21nm
from tfn.edge_table_lsoa a, tfn.edge_table_lsoa2 b
where a.id = b.id and a.segment_length = b.segment_length;

create index edge_table_lsoa3_idx on tfn.edge_table_lsoa3 using GIST (geometry);

--CREATE TABLE STATEMENT FOR NGD BUS LANES
drop table tfn.bus_lanes;
create table tfn.bus_lanes (
	osid       					text,
	versiondate					date,
	versionavailablefromdate 	text,
	versionavailabletodate		text,
	changetype					text,
	geometry 					text,
	geometry_length_m 			float,
	geometry_evidencedate 		date,
	geometry_updatedate    		date,
	geometry_capturemethod 		text,
	theme 						text,
	description 				text,
	parentid 					text,
	sideofroad 					text,
	buslaneinfo_minimumwidth_m 	float,
	buslaneinfo_modalwidth_m 	float,
	buslaneinfo_direction 		text,
	buslaneinfo_evidencedate 	date,
	buslaneinfo_updatedate 		date,
	buslaneinfo_capturemethod 	text,
	linkid 						text,
	linkid_featuretype 			text,
	linkid_confidence 			text,
	linkid_evidencedate 		date,
	linkid_updatedate 			date,
	linkid_capturemethod 		text);

copy tfn.bus_lanes from 'D:\\Data\\tfn\\trn_ntwk_buslane\\trn_ntwk_buslane.csv' with header delimiter ',' quote '"' encoding 'utf8' csv;--637192

--CREATE THE GEOMETRY COLUMN
drop table tfn.bus_lanes2;
create table tfn.bus_lanes2 as
select osid, st_geomfromtext(geometry, 27700) as geom
from tfn.bus_lanes;

create index bus_lanes2_geom on tfn.bus_lanes2 using GIST (geom);

--LOAD IN GTFS DATA WITH QGIS PLUGIN GTFS GO
--TRANSLATE THE GTFS BUS STOPS AND ROUTES TO BNG PROJECTION
create table tfn.stops_gtfs2 as
select id, st_transform(geom, 27700) as geom, stop_id, stop_name, route_ids
from tfn.stops_gtfs;

create index stops_gtfs2_idx on tfn.stops_gtfs2 using GIST (geom);

create table tfn.routes_gtfs2 as
select id, st_transform(geom, 27700) as geom, route_id, route_name
from tfn.routes_gtfs;

create index routes_gtfs2_idx on tfn.routes_gtfs2 using GIST (geom);

--LOAD IN STOP TIMES FROM GTFS DATA FOR THE STOP SEQUENCE
create table tfn.stop_times (
	trip_id					text,
	arrival_time			text,
	departure_time			text,
	stop_id 				text,
	stop_sequence           int,
	stop_headsign   		text,
	pickup_type 			text,
	drop_off_type			text,
	shape_dist_traveled 	text,
	timepoint 				text);

copy tfn.stop_times from 'D:\\Data\\tfn\\itm_yorkshire_gtfs\\stop_times.txt' with header delimiter ',' quote '"' encoding 'utf8' csv;--637192

--LOAD IN TRIP DATA TOO TO MATCH THE STOPS TO THE ROUTES
create table tfn.trips (
	route_id 				text,
	service_id 				text,
	trip_id 				text,
	trip_headsign 			text,
	direction_id 			text,
	block_id 				text,
	shape_id 				text,
	wheelchair_accessible 	text,
	vehicle_journey_code 	text);

copy tfn.trips from 'D:\\Data\\tfn\\itm_yorkshire_gtfs\\trips.txt' with header delimiter ',' quote '"' encoding 'utf8' csv;--637192

--JOIN ABPLUS WITH THE LSOA TABLE USING ST_DWITHIN
drop table tfn.abplus_lsoa;
create table tfn.abplus_lsoa as
select a.uprn, a.class, a.geom, b.lsoa21cd, b.lsoa21nm 
from abplus_20251016.addressbaseplus a, tfn.lsoa b
where substr(a.class,1,1) in ('R','C') and st_dwithin(a.geom, b.geom, 0);

--EXAMPLE QUERY FOR PULLING OUT A CUT OF THE EDGE TABLE FOR ROUTING
create table tfn.route_bbox as
WITH start AS (
  SELECT b.source, b.target, b.id, b.geometry
    FROM tfn.stops_gtfs2 a, tfn.edge_table b
	WHERE a.stop_id = '2290YHA01181'
	  AND st_dwithin(a.geom,b.geometry,100)
	  AND b.highway not in ('footway')
	ORDER BY a.geom <-> b.geometry LIMIT 1),
	dest AS (
   SELECT b.source, b.id, b.geometry
     FROM tfn.stops_gtfs2 a, tfn.edge_table b
	WHERE a.stop_id = '2200YEA00153'
	  AND st_dwithin(a.geom,b.geometry,100)
	  AND b.highway not in ('footway')
    ORDER BY a.geom <-> b.geometry LIMIT 1),
	bbox1 AS (
	  select geometry from start
	   union
	  select geometry from dest
	),
	bbox2 AS (
      select st_buffer(st_setsrid(st_envelope(st_extent(geometry)),27700),200) as geom from bbox1
	),
	route_bbox AS (
	  select b.* from bbox2 a, tfn.edge_table b where st_dwithin(a.geom, b.geometry, 0)
	)
	select * from route_bbox;

--AND AN EXAMPLE OF HOW TO ROUTE WITH THE RESULTS OF THE BBOX
SELECT ST_Union(geometry) AS route
  FROM pgr_dijkstra(
  'SELECT id, source, target, cost, reverse_cost FROM tfn.route_bbox',
  ARRAY(SELECT source FROM tfn.route_bbox where id = 1104201070),
  ARRAY(SELECT source FROM tfn.route_bbox where id = 1107955243)
   ) AS di
   JOIN tfn.route_bbox AS pt
   ON di.edge = pt.id;

--FUNCTION FOR CHECKING ONEWAY MERGING, SOMETIMES MRN FLIPS THE DIRECTIONALITY WHICH IS FINE AT THE DETAILED LEVEL BUT CAUSES PROBLEMS WHEN AGGREGATING
DROP FUNCTION oneway_checks();
CREATE OR REPLACE FUNCTION oneway_checks()
RETURNS INT AS $$
	--THIS CODE STRIPS OUT LEGITIMATE ONEWAY DIFFERENCES AT PLACES LIKE ROUNDABOUT JUNCTIONS WHERE ONEWAY DIFFERENCES ARE LEGITIMATE
	with oneway_step1 AS (
	select a.id1, a.id2, a.source1, b.source_count as srccnt1, a.source2, c.source_count as srccnt2, a.target1, 
	       d.source_count as trgcnt1, a.target2, e.source_count as trgcnt2
	  from tfn.simplify_level2_oneway_check a, tfn.simplify_level4 b, tfn.simplify_level4 c, tfn.simplify_level4 d,
	       tfn.simplify_level4 e
	 where a.source1 = b.source and a.source2 = c.source and a.target1 = d.source and a.target2 = e.source order by a.id1 limit 1)
	delete from tfn.simplify_level2_oneway_check where (id1, id2) in (select id1, id2 from oneway_step1 where srccnt2 > 2 and trgcnt2 > 2);
	
	with oneway_step1 AS (
	select a.id1, a.id2, a.source1, b.source_count as srccnt1, a.source2, c.source_count as srccnt2, a.target1, 
	       d.source_count as trgcnt1, a.target2, e.source_count as trgcnt2
	  from tfn.simplify_level2_oneway_check a, tfn.simplify_level4 b, tfn.simplify_level4 c, tfn.simplify_level4 d,
	       tfn.simplify_level4 e
	 where a.source1 = b.source and a.source2 = c.source and a.target1 = d.source and a.target2 = e.source order by a.id1 limit 1),
	     oneway_step2 AS (
	select case when source1 = source2 and srccnt1 > 2 and srccnt2 > 2 then source1
	            when source1 = target2 and srccnt1 > 2 and trgcnt2 > 2 then source1
				when target1 = source2 and trgcnt1 > 2 and srccnt2 > 2 then target1
		   else 0
		   end as test from oneway_step1)
	delete from tfn.simplify_level2_oneway_check where (id1, id2) in (select id1, id2 from oneway_step1 where (select * from oneway_step2) != 0);
	
	with oneway_deletes1 as (
		select id1 from tfn.simplify_level2_oneway_check order by id1 limit 1),
		 oneway_deletes2 as (
		select a.id1, a.source1 from tfn.simplify_level2_oneway_check a, oneway_deletes1 b where a.id1 = b.id1 and (a.source1 = a.source2 or a.source1 = a.target2)),
		 oneway_deletes3 as (
		select a.id1, a.target1 from tfn.simplify_level2_oneway_check a, oneway_deletes1 b where a.id1 = b.id1 and (a.target1 = a.source2 or a.target1 = a.target2)),
		 oneway_deletes4 as (
		select a.id1, b.source, b.source_count from oneway_deletes2 a, tfn.simplify_level4 b where a.source1 = b.source),
		 oneway_deletes5 as (
		select a.id1, b.source, b.source_count from oneway_deletes3 a, tfn.simplify_level4 b where a.target1 = b.source),
		 oneway_deletes6 as (
		select id1, source from oneway_deletes4 where source_count > 2 union select id1, source from oneway_deletes5 where source_count > 2),
		 oneway_deletes7 as (
	    select a.id1 from tfn.simplify_level2_oneway_check a, oneway_deletes6 b where a.id2 = b.id1
		union
		select id1 from oneway_deletes6)
	delete from tfn.simplify_level2_oneway_check where id1 in (select id1 from oneway_deletes7);

	--this is to handle situations where the node being flagged falls just outside of the lsoa boundary and so part of the road connecting on can be missing from the processing table
	--things like a dual carriageway merging to single, with the single part being the missing link and the process thinking the place where the carriageways merge should be joined
	with oneway_deletes1 as (select id1 from tfn.simplify_level2_oneway_check order by id1 limit 1),
     	 oneway_deletes2 as (select a.id1, a.source1 from tfn.simplify_level2_oneway_check a, oneway_deletes1 b where a.id1 = b.id1 and (a.source1 = a.source2 or a.source1 = a.target2)),
     	 oneway_deletes3 as (select a.id1, count(b.*) as rowcount, count(distinct b.name) as namecount, count(distinct b.highway) as highwaycount from oneway_deletes1 a, tfn.edge_table b where source in (select source1 from oneway_deletes2) or target in (select source1 from oneway_deletes2) group by a.id1)
	delete from tfn.simplify_level2_oneway_check where id1 in (select id1 from oneway_deletes3 where rowcount = 3 and namecount = 1 and highwaycount = 1);

	select count(*) as oneway_count from tfn.simplify_level2_oneway_check;
$$ LANGUAGE SQL;

--FUNCTION FOR COUNTING UP THE NODES IN THE PROCESSING TABLE FOR CHECKING FOR MERGING ERRORS
DROP FUNCTION node_checks();
CREATE OR REPLACE FUNCTION node_checks()
RETURNS VOID AS $$
	BEGIN
		--GET COUNTS FOR SOURCE AND TARGET NODES
		drop table tfn.simplify_level3;
		create table tfn.simplify_level3 as
		select source, count(source) as source_count from tfn.simplify_level2 where source != target group by source;
	
		insert into tfn.simplify_level3
		select target, count(target) as source_count from tfn.simplify_level2 where target != source group by target;
	
		drop table tfn.simplify_level4;
		create table tfn.simplify_level4 as
		select source, sum(source_count) as source_count from tfn.simplify_level3 
		 where source not in (select source_to_remove from tfn.oneway_fix_nodes) group by source order by sum(source_count) desc;
	
		--SELECT A CANDIDATE NODE TO START WITH WHICH HAS A COUNT OF 2 (NOT A JUNCTION) 
		drop table tfn.simplify_level4_node;
		create table tfn.simplify_level4_node as
		select source from tfn.simplify_level4 
		 where source in (select a.nodeid from tfn.node_table a, tfn.lsoa b where b.lsoa21cd = (select * from tfn.next_lsoa_id) 
		   and st_dwithin(a.geom,b.geom,250)) 
		   and source_count = 2
		   and source not in (select source from tfn.oneway_avoid_nodes) order by source limit 1;
	END;
$$ LANGUAGE PLPGSQL;

--FUNCTION FOR HANDLING ERRONEOUS MERGING INVOLVING MORE THAN 2 LINKS AT A JUNCTION
DROP FUNCTION multi_merge_checks();
CREATE OR REPLACE FUNCTION multi_merge_checks()
RETURNS VOID AS $$
	BEGIN
		drop table tfn.simplify_level3;
		create table tfn.simplify_level3 as
		select source, count(source) as source_count from tfn.simplify_level2 
		where source in (select source from tfn.edge_table where id::text in (select unnest(original_ids1) as original_ids from tfn.erroneous_intersections
		                                                					   where id1 in (select id1 from tfn.erroneous_intersections order by id1 limit 1)
														                       union
														                      select unnest(original_ids2) as original_ids from tfn.erroneous_intersections
														                       where id1 in (select id1 from tfn.erroneous_intersections order by id1 limit 1)
																			   union
																			  select unnest(original_ids) as original_ids from tfn.more_than_two_links))
		   or source in (select target from tfn.edge_table where id::text in (select unnest(original_ids1) as original_ids from tfn.erroneous_intersections
		                                                					   where id1 in (select id1 from tfn.erroneous_intersections order by id1 limit 1)
														                       union
														                      select unnest(original_ids2) as original_ids from tfn.erroneous_intersections
														                       where id1 in (select id1 from tfn.erroneous_intersections order by id1 limit 1)
																			   union
																			  select unnest(original_ids) as original_ids from tfn.more_than_two_links)) group by source;

		--and then rerun for the target
		insert into tfn.simplify_level3
		select a.target, count(a.target) as source_count from tfn.simplify_level2 a
		where a.target in (select source from tfn.edge_table where id::text in (select unnest(original_ids1) as original_ids from tfn.erroneous_intersections
		                                                					   where id1 in (select id1 from tfn.erroneous_intersections order by id1 limit 1)
														                       union
														                      select unnest(original_ids2) as original_ids from tfn.erroneous_intersections
														                       where id1 in (select id1 from tfn.erroneous_intersections order by id1 limit 1)
																			   union
																			  select unnest(original_ids) as original_ids from tfn.more_than_two_links))
		   or a.target in (select target from tfn.edge_table where id::text in (select unnest(original_ids1) as original_ids from tfn.erroneous_intersections
		                                                					   where id1 in (select id1 from tfn.erroneous_intersections order by id1 limit 1)
														                       union
														                      select unnest(original_ids2) as original_ids from tfn.erroneous_intersections
														                       where id1 in (select id1 from tfn.erroneous_intersections order by id1 limit 1)
																			   union
																			  select unnest(original_ids) as original_ids from tfn.more_than_two_links)) group by a.target;
		
		--take out any source or target nodes that don't intersect the affected links
				--unnest the merged id links to join to the original MRN table
		with err_int_test1 as (select unnest(original_ids1) as original_ids from tfn.erroneous_intersections
		                        where id1 in (select id1 from tfn.erroneous_intersections order by id1 limit 1)
		                        union
						       select unnest(original_ids2) as original_ids from tfn.erroneous_intersections
				                where id1 in (select id1 from tfn.erroneous_intersections order by id1 limit 1)
								union
							   select unnest(original_ids) as original_ids from tfn.more_than_two_links),
		     err_int_test2 as (select a.original_ids, b.geometry from err_int_test1 a, tfn.edge_table b where a.original_ids::int = b.id),
			 err_int_test3 as (select a.source, b.geom from tfn.simplify_level3 a, tfn.node_table b where a.source = b.nodeid),
			 err_int_test4 as (select a.*, st_distance(a.geom, st_union(b.geometry)) as dist from err_int_test3 a, err_int_test2 b group by a.source, a.geom),
		     err_int_test5 as (select source from err_int_test4 where dist > 0)
		delete from tfn.simplify_level3 where source in (select source from err_int_test5);

		--Count the nodes that are left
		drop table tfn.simplify_level4;
		create table tfn.simplify_level4 as
		select source, sum(source_count) as source_count from tfn.simplify_level3 
		 where source not in (select source_to_remove from tfn.oneway_fix_nodes) group by source order by sum(source_count) desc;

		--check the node counts from whats left, and find the ones where the source count is greater than 2 (junction)
		with err_int_test1 as (select a.source, a.source_count, count(b.id) as full_src_count 
                         		 from tfn.simplify_level4 a, tfn.simplify_level2 b
                        	    where (a.source = b.source or a.source = b.target)
                        		group by a.source, a.source_count),
     		 err_int_test2 as (select * from err_int_test1 where full_src_count > source_count and source_count = 2)
     	--delete them from the candidate nodes
		delete from tfn.simplify_level4 where source in (select source from err_int_test2);

		--find any nodes from the affected links where a oneway change has happened that needs to be left out to avoid re-merging
		drop table tfn.err_int_oneway_test;
		create table if not exists tfn.err_int_oneway_test as
		select a.id as id1, a.name as name1, a.oneway as oneway1, b.oneway as oneway2, a.source as source1, a.target as target1, a.length as length1, a.cost, a.reverse_cost, 
		       b.id as id2, b.name as name2, b.source as source2, b.target as target2, b.length as length2
		  from tfn.simplify_level2 a, tfn.simplify_level2 b
		 where a.id::text in (select unnest(original_ids1) as original_ids from tfn.erroneous_intersections
		 	                   where id1 in (select id1 from tfn.erroneous_intersections order by id1 limit 1)
		 	                   union
		 	                  select unnest(original_ids2) as original_ids from tfn.erroneous_intersections
		 	                   where id1 in (select id1 from tfn.erroneous_intersections order by id1 limit 1)
		 	                   union
		 	                  select unnest(original_ids) as original_ids from tfn.more_than_two_links)
		   and ((a.source = b.source or a.source = b.target) or (a.target = b.source or a.target = b.target))
		   and a.id != b.id;

		--identify the node that connects the two links
		alter table tfn.err_int_oneway_test add column source_to_check int;
		update tfn.err_int_oneway_test set source_to_check = source1 where source1 = source2 or source1 = target2;
		update tfn.err_int_oneway_test set source_to_check = target1 where target1 = source2 or target1 = target2;

		--remove any rows where the oneway attributes are the same
		delete from tfn.err_int_oneway_test where oneway1 = oneway2;
		--remove any rows where they're both null values
		delete from tfn.err_int_oneway_test where oneway1 is null and oneway2 is null;

		--remove rows where the source node involved appears more than twice in the links being looked at
		with err_int_oneway_test_check as (select a.*, b.source_count from tfn.err_int_oneway_test a left outer join tfn.simplify_level4 b on a.source_to_check = b.source)
		delete from tfn.err_int_oneway_test where source_to_check in (select source_to_check from err_int_oneway_test_check where source_count > 2);

		--insert these nodes into the prep table for use later
		insert into tfn.oneway_source_to_check
		select distinct source_to_check from tfn.err_int_oneway_test
		 where source_to_check not in (select source_to_check from tfn.oneway_source_to_check);

		--load in a node to merge
		drop table tfn.simplify_level4_node;
		create table tfn.simplify_level4_node as
		select source from tfn.simplify_level4 
		 where source_count = 2
		   and source not in (select source_to_check from tfn.oneway_source_to_check) order by source limit 1;
	END;
$$ LANGUAGE PLPGSQL;

--CREATE THIS TABLE ONCE, READY TO HOLD ONEWAY MERGING NODES FOR PROCESSING
create table tfn.oneway_fix_nodes (
	source_to_remove		int,
	id1						int,
	id2						int
);

--CREATE THIS TABLE ONCE, READY TO HOLD ONEWAY MERGING NODES THAT SHOULD NOT BE PROCESSED
create table tfn.oneway_avoid_nodes (
	id						int,
	oneway					text,
	source					int
);

--CREATE THIS TABLE ONCE, READY TO HOLD ID VALUES WHEN HANDLING MULTIPLE LINKS INTERSECTING A WRONGLY MERGED LINK
create table tfn.more_than_two_links (
	id1				int,
	original_ids	text array
);

--CREATE THIS TABLE ONCE, READY TO HOLD SOURCE VALUES WHEN HANDLING ONE WAY CHANGES IN A WRONGLY MERGED LINK
create table tfn.oneway_source_to_check (
	source_to_check 	int
);