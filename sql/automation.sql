----THESE FIRST QUERIES WILL CHANGE DEPENDING ON WHAT GEOGRAPHIES ARE BEING USED TO SIMPLIFY THE NETWORK.
----THE BELOW IS BASED ON LSOA POLYGONS
--SELECT LSOA ID
drop table tfn.next_lsoa_id;
create table tfn.next_lsoa_id as select 'E01013176' as lsoa21cd;

--SELECT LSOA NAME
drop table tfn.next_lsoa_name;
create table tfn.next_lsoa_name as select 'North East Lincolnshire 001C';

--CREATE AN EXTERIOR RING OF THE LSOA AND INTERSECT MRN WITH IT, IGNORING MRN LINKS THAT ARE FOOTPATHS AND TRACKS
--IF ONLY CERTAIN ROADS ARE WANTED FOR CROSSING LSOA'S THIS IS WHERE TO FILTER THEM
drop table tfn.simplify_level1;
create table tfn.simplify_level1 as
with ext_ring as (
	select st_exteriorring((st_dump(geom)).geom) as geom from tfn.lsoa where lsoa21cd = (select * from tfn.next_lsoa_id))
select a.* from tfn.edge_table a, ext_ring b
where st_dwithin(a.geometry,b.geom,0)
  and highway not in ('footway','track')
  and name is not null;

--IF GTFS DATA IS AVAILABLE, READ IN THE STOPS AND ADD IN ANY ROADS IN THE LSOA THAT DON'T GET PICKED UP BY THE INTERSECT
with bus_stop_roads as (
	select c.* from tfn.stops_gtfs2 a, tfn.lsoa b, tfn.edge_table c
	where b.lsoa21cd = (select * from tfn.next_lsoa_id) and st_dwithin(a.geom,b.geom,0) 
  	  and st_dwithin(a.geom,c.geometry,12) limit 100)
insert into tfn.simplify_level1 select * from bus_stop_roads where id not in (select id from tfn.simplify_level1);

--PULL OUT ALL ROADS THAT ARE WITHIN A BUFFER OF THE LSOA AND SHARE A ROADNAME WITH ROADS INTERSECTING THE BOUNDARY
drop table tfn.simplify_level1_checks;
create table tfn.simplify_level1_checks as
select sum(a.length) as length, a.name
from tfn.edge_table a, tfn.lsoa b
where b.lsoa21nm = (select * from tfn.next_lsoa_name)
  and st_dwithin(a.geometry, st_buffer(b.geom,150), 0)
  and a.name in (select name from tfn.simplify_level1)
group by a.name;

--ADD IN THOSE THAT ARE INSIDE THE LSOA AND DON'T INTERSECT THE BOUNDARY
--LEFT THIS OPEN FOR ADJUSTING IF THERE IS MORE INFO AVAILABLE ON WHAT ROADS TO LEAVE OUT
drop table tfn.simplify_level2;
create table tfn.simplify_level2 as
select a.* from tfn.edge_table a, tfn.lsoa b
where b.lsoa21nm = (select * from tfn.next_lsoa_name)
  and st_dwithin(a.geometry, st_buffer(b.geom,50), 0)
  and a.name in (select name from tfn.simplify_level1_checks where length >= 226
                                                               and name not like '%Crescent'
															   and name not like '%Grove');

--ADD IN LINKS THAT HAVEN'T BEEN PICKED UP THAT HAVE ROAD OR ROUNDABOUT IN THE NAME FROM ROADS THAT INTERSECTED THE BOUNDARY
insert into tfn.simplify_level2
select a.* from tfn.edge_table a, tfn.lsoa b
where b.lsoa21nm = (select * from tfn.next_lsoa_name)
  and st_dwithin(a.geometry, st_buffer(b.geom,50), 0)
  and a.name in (select name from tfn.simplify_level1_checks where name like '% Road%' or name like '% Roundabout%')
  and a.id not in (select id from tfn.simplify_level2);

--ADD IN ROUNDABOUT LINKS THAT HAVEN'T BEEN PICKED UP AND ARE INSIDE THE LSOA
insert into tfn.simplify_level2
select a.* from tfn.edge_table a, tfn.lsoa b
where b.lsoa21nm = (select * from tfn.next_lsoa_name)
  and st_dwithin(a.geometry, st_buffer(b.geom,50), 0)
  and a.name like '% Roundabout%'
  and a.id not in (select id from tfn.simplify_level2);

--MRN WILL SOMETIMES HAVE 2 ROADNAMES FOR A LINK, SEPARATED BY A /. THESE 3 INSERTS CHECK FOR THOSE
insert into tfn.simplify_level2
select distinct a.* from tfn.edge_table a, tfn.lsoa b, tfn.simplify_level1 c
where b.lsoa21nm = (select * from tfn.next_lsoa_name)
  and c.name not like '%/%'
  and st_dwithin(a.geometry, st_buffer(b.geom,50), 0)
  and a.name like '%/%'
  and a.name like '%' || c.name || '%'
  and a.id not in (select id from tfn.simplify_level2);

insert into tfn.simplify_level2
select distinct a.* from tfn.edge_table a, tfn.lsoa b, tfn.simplify_level2 c
where b.lsoa21nm = (select * from tfn.next_lsoa_name)
  and c.name like '%/%'
  and st_dwithin(a.geometry, st_buffer(b.geom,50), 0)
  and a.name not like '%/%'
  and c.name like '%' || a.name || '%'
  and a.highway != 'footway'
and a.id not in (select id from tfn.simplify_level2);

insert into tfn.simplify_level2
select distinct a.* from tfn.edge_table a, tfn.lsoa b, tfn.simplify_level2 c
where b.lsoa21nm = (select * from tfn.next_lsoa_name)
  and c.name not like '%/%'
  and st_dwithin(a.geometry, st_buffer(b.geom,50), 0)
  and a.name like '%/%'
  and a.name like '%' || c.name || '%'
and a.id not in (select id from tfn.simplify_level2);

--ADD IN ANY LINKS THAT HAVEN'T BEEN PICKED UP YET THAT HAVE A HIGHWAY CLASSIFICATION ABOVE RESIDENTIAL
insert into tfn.simplify_level2
select distinct a.* from tfn.edge_table a, tfn.lsoa b
where b.lsoa21nm = (select * from tfn.next_lsoa_name)
  and st_dwithin(a.geometry, b.geom, 0)
  and a.highway in ('primary','trunk','secondary','tertiary')
  and a.id not in (select id from tfn.simplify_level2);

--ADD IN ANY ROUNDABOUT LINKS THAT HAVE BEEN MISSED THAT INTERSECT LINKS ALREADY IN THE PROCESSING TABLE
with roundabout_inserts as (
		select a.* from tfn.edge_table a, tfn.lsoa b
		where b.lsoa21nm = (select * from tfn.next_lsoa_name)
		  and st_dwithin(a.geometry, st_buffer(b.geom,50), 0)
		  and a.junction = 'roundabout'
		  and a.id not in (select id from tfn.simplify_level2)),
	 roundabout_inserts2 as (
		select a.id, b.id target, b.d distance 
		  from roundabout_inserts a cross join lateral
		       (select distinct on (a.id) b.id,
			    a.geometry <-> b.geometry d
				from tfn.simplify_level2 as b where st_dwithin(a.geometry,b.geometry,0)
				order by a.id, d asc
				) as b)
insert into tfn.simplify_level2
select distinct a.* from tfn.edge_table a, roundabout_inserts2 b
where a.id = b.id;

----FOR MANUALLY ADDING IN ANY ROADLINKS THAT AREN'T PICKED UP FOR THINGS LIKE BUS ROUTES THAT GO INTO RESIDENTIAL OR SITE AREAS
----LEFT COMMENTED SO IT ONLY ADDS IN WHEN NEEDED
----USE MRN LINK ID'S FOR THE INSERTION
--insert into tfn.simplify_level2 select a.* from tfn.edge_table a 
--where a.id in (1100422312,1102137905,1107357467,1107862809,1104723904,1105034828,1103452904,1101091666)
--  and a.id not in (select id from tfn.simplify_level2);

--CREATE AN ARRAY COLUMN TO PUT THE ORIGINAL ID READY FOR MERGING LATER
alter table tfn.simplify_level2 add column original_ids text[];

--POPULATE THE ARRAY COLUMN
update tfn.simplify_level2 set original_ids = array[id::text] where original_ids is null;

--THE FULL TABLE WILL BE WHERE EACH PROCESSED LSOA'S NETWORK WILL GO TO
--THIS STEP REMOVES ANY LINKS THAT HAVE BEEN PICKED UP THAT ALREADY APPEAR IN THAT FULL TABLE
delete from tfn.simplify_level2 where id in (select id from tfn.simplify_level_full);

--THIS STEP CHECKS FOR AND REMOVES ANY IDS FOR LINKS THAT HAVE BEEN PICKED UP AND AREA ALREADY MERGED INTO A SIMPLIFIED LINK
delete from tfn.simplify_level2 where id in (select a.id from tfn.simplify_level2 a, tfn.simplify_level_full b where a.id::text = ANY (b.original_ids));

--GET RID OF THE ROWID COLUMN FROM THE FULL TABLE, IT'LL GET RECREATED EACH TIME AN LSOA IS PROCESSED. THEN INSERT INTO THE PICKED UP LINKS TABLE
alter table tfn.simplify_level_full drop column rowid;
insert into tfn.simplify_level2 select * from tfn.simplify_level_full;

----THIS SECTION DOES A QUICK CHECK ON THE NOTES IN THE RESULTING TABLE TO GET A COUNT OF HOW MANY TIMES THEY APPEAR
----THIS LEADS TO IDENTIFYING WHICH NEED MERGING, WHICH CAN BE IGNORED, AND WHICH MIGHT NEED ANOTHER INTERVENTION
----RUN THIS FOR BOTH SOURCE AND TARGET NODES
drop table tfn.simplify_level3;
create table tfn.simplify_level3 as
select source, count(source) as source_count from tfn.simplify_level2 group by source;

insert into tfn.simplify_level3
select target, count(target) as source_count from tfn.simplify_level2 group by target;

--COUNT UP THE TIMES EACH NODE APPEARS
drop table tfn.simplify_level4;
create table tfn.simplify_level4 as
select source, sum(source_count) as source_count from tfn.simplify_level3
 group by source order by sum(source_count) desc;

----THIS SEQUENCE CHECKS FOR ONEWAYS THAT NEED TO BE ADJUSTED WHEN SIMPLIFYING
----SOMETIMES THE DIRECTIONALITY IS FLIPPED IN MRN, SO THAT WHEN COSTS ARE AGGREGATED THERE IS A PROBLEM IF NOT CHANGED
--THIS PART CHECKS LINK ID'S AND NODES WHERE THERE IS A MISMATCH BETWEEN THE ONEWAY ATTRIBUTE
drop table tfn.simplify_level2_oneway_check;
create table tfn.simplify_level2_oneway_check as
select a.id as id1, a.name as name1, a.oneway as oneway1, b.oneway as oneway2, a.source as source1, a.target as target1, a.length as length1, a.cost, a.reverse_cost, 
       b.id as id2, b.name as name2, b.source as source2, b.target as target2, b.length as length2
  from tfn.simplify_level2 a, tfn.simplify_level2 b
 where a.oneway in ('-1','yes','no') and b.oneway in ('-1','yes','no') and a.oneway != b.oneway and a.id != b.id and ((a.source = b.source or a.source = b.target) or (a.target = b.source or a.target = b.target))
  and (a.source in (select source from tfn.simplify_level4 where source_count = 2) or a.target in (select source from tfn.simplify_level4 where source_count = 2))
 order by a.id;

--DELETE ANY ROWS THAT WERE PICKED UP WHERE THE NAME BETWEEN THE TWO CANDIDATE LINKS DOESN'T MATCH
delete from tfn.simplify_level2_oneway_check where name1 != name2;

--ROUNDABOUTS SHOULD ALWAYS HAVE THE SAME DIRECTIONALITY, SO STRIP THOSE OUT	
delete from tfn.simplify_level2_oneway_check where id2 in (select a.id2
                                                             from tfn.simplify_level2_oneway_check a,
															      tfn.edge_table b,
																  tfn.lsoa c
															where a.id2 = b.id
															  and c.lsoa21nm = (select * from tfn.next_lsoa_name)
															  and b.junction = 'roundabout'
															  and st_distance(b.geometry,c.geom) = 0);

--TAKE OUT ANY CANDIDATE NODES THAT ARE OUTSIDE OF THE LSOA BEING PROCESSED
delete from tfn.simplify_level2_oneway_check where id1 in (select a.id1
                                                             from tfn.simplify_level2_oneway_check a,
															      tfn.edge_table b,
																  tfn.lsoa c
														    where a.id1 = b.id
															  and c.lsoa21nm = (select * from tfn.next_lsoa_name)
															  and st_distance(b.geometry,c.geom) > 0
															  and b.highway != 'trunk');

--THIS CODE STRIPS OUT LEGITIMATE ONEWAY DIFFERENCES AT PLACES LIKE ROUNDABOUT JUNCTIONS WHERE ONEWAY DIFFERENCES ARE LEGITIMATE
--ANY DIFFERENCES THAT NEED SORTING GET PLACED INTO A TEMP TABLE, SO THAT THE NODES INVOLVED CAN BE IGNORED FROM THE MERGING AND HANDLED SEPARATELY
do
$$
declare oneways_to_fix int := 1;
        oneways_to_fix_check int := 1;
begin
	while (oneways_to_fix > 0) loop

		select * from oneway_checks() into oneways_to_fix;
		select * from oneway_checks() into oneways_to_fix_check;

		IF (oneways_to_fix = oneways_to_fix_check) THEN

			insert into tfn.oneway_fix_nodes
			with oneway_fixing1 AS(
				(select source1, id1, id2 from tfn.simplify_level2_oneway_check where (source1 = source2 or source1 = target2) and id1 in (select id1 from tfn.simplify_level2_oneway_check order by id1 limit 1))
				union
				(select target1, id1, id2 from tfn.simplify_level2_oneway_check where (target1 = source2 or target1 = target2) and id1 in (select id1 from tfn.simplify_level2_oneway_check order by id1 limit 1)))
			select source1 as source_to_remove, id1, id2 from oneway_fixing1;

			delete from tfn.simplify_level2_oneway_check where id1 in (select id1 from tfn.oneway_fix_nodes union select id2 from tfn.oneway_fix_nodes);

		ELSE perform oneway_checks();
		END IF;

	end loop;
end;
$$;

--FUNCTION CALL TO DO THE NODE COUNT CHECKS FOR TESTING FOR ONEWAY DIFFERENCES WHERE A MERGE ISN'T NEEDED
select node_checks();

with oneway_testing as
	(select distinct a.id, a.oneway, b.source 
	  from tfn.simplify_level2 a, tfn.simplify_level4 b
	 where b.source_count = 2
	   and (a.source = b.source
	    or a.target = b.source))
insert into tfn.oneway_avoid_nodes
select a.* from oneway_testing a, tfn.simplify_level2 b 
 where (a.source = b.source or a.source = b.target) and a.id != b.id
   and a.oneway is null and b.oneway in ('yes','no','-1');

--FUNCTION CALL TO DO THE NODE COUNT CHECKS AND LOAD IN A CANDIDATE NODE FOR MERGING
select node_checks();

--THIS NEXT PROCESS THEN RUNS THE MERGING FOR THE LINKS WITHIN THE LSOA
do
$$
declare nodes_to_merge int := 1;
        next_node int;
begin
	while (nodes_to_merge > 0) loop
		with links_to_merge AS (
				select * from tfn.simplify_level2 where source = (select source from tfn.simplify_level4_node) or target = (select source from tfn.simplify_level4_node)),
			 next_id_to_use AS (
		    	select max(id) + 1 as id from tfn.simplify_level2),
			 id_collecting AS (
				select unnest(original_ids) as original_ids from links_to_merge),
			 id_collected AS (
				select array_agg(original_ids) as original_ids from id_collecting),
			 roadname_collecting1 AS (
				select regexp_replace(unnest(string_to_array(name,',')),'{','') as roadnames from links_to_merge),
			 roadname_collecting2 AS (
		 		select regexp_replace(roadnames,' / ','_') as roadnames from roadname_collecting1),
			 roadname_collecting3 AS (
		    	select replace(roadnames,'"','') as roadnames from roadname_collecting2),
			 roadname_collecting4 AS (
				select replace(roadnames,'}','') as roadnames from roadname_collecting3),
			 roadname_collected AS (
				select array_agg(distinct roadnames) as name from roadname_collecting4),
			 foot_collecting1 AS (
				select regexp_replace(unnest(string_to_array(foot,',')),'{','') as foot from links_to_merge),
			 foot_collecting2 AS (
		    	select regexp_replace(foot,'}','') as foot from foot_collecting1),
			 foot_collected AS (
		    	select array_agg(distinct foot) as foot from foot_collecting2),
			 prep_for_merge AS (
				select (select id from next_id_to_use) as id, (select original_ids from id_collected) as original_ids, (select name from roadname_collected) as name, --array_to_string(array_agg(distinct name),',') as name,
			       (select foot from foot_collected) as foot, array_to_string(array_agg(distinct highway),',') as highway,
				   array_to_string(array_agg(distinct railway),',') as railway, array_to_string(array_agg(distinct rail),',') as rail,
				   array_to_string(array_agg(distinct ferry),',') as ferry, array_to_string(array_agg(distinct toll),',') as toll,
				   array_to_string(array_agg(distinct junction),',') as junction, array_to_string(array_agg(distinct route),',') as route,
				   array_to_string(array_agg(distinct ford),',') as ford, array_to_string(array_agg(distinct bridge),',') as bridge,
				   array_to_string(array_agg(distinct tunnel),',') as tunnel, array_to_string(array_agg(distinct service),',') as service,
				   array_to_string(array_agg(distinct oneway),',') as oneway, sum(length) as length, sum(cost) as cost,
				   sum(reverse_cost) as reverse_cost, st_astext(st_linemerge(st_collect(st_setsrid(geometry,27700)))) as geom from links_to_merge),
			 endpoints AS (
			    select st_setsrid(st_startpoint(geom),27700) as startpos, st_setsrid(st_endpoint(geom),27700) as endpos from prep_for_merge),
			 newsource AS (
			   	select a.startpos, b.nodeid from endpoints a, tfn.node_table b where st_dwithin(a.startpos,b.geom,0) and (b.nodeid in (select source from tfn.simplify_level4)
			   																										  or b.nodeid in (select source_to_remove from tfn.oneway_fix_nodes))),
			 newtarget AS (
		       	select a.endpos, b.nodeid, st_distance(a.endpos, b.geom) from endpoints a, tfn.node_table b where st_dwithin(a.endpos,b.geom,0) and (b.nodeid in (select source from tfn.simplify_level4)
			                                                                                                            or b.nodeid in (select source_to_remove from tfn.oneway_fix_nodes))),
			 newrecord AS (
			   	insert into tfn.simplify_level2
			   	select a.id, a.name, a.foot, a.highway, a.railway, a.rail, a.ferry, a.toll, a.junction, a.route, a.ford, a.bridge, a.tunnel, a.service,
			           a.oneway, a.length, b.nodeid as source, c.nodeid as target, a.cost, a.reverse_cost, a.geom, a.original_ids
			      from prep_for_merge a, newsource b, newtarget c)
		delete from tfn.simplify_level2 where id in (select id from links_to_merge);

		--RERUN THE NODE COUNTS, PREP THE NEXT CANDIDATE NODE FOR MERGING
		perform node_checks();

		--READ THE COUNT FROM THE CANDIDATE TABLE INTO THE TEMP VARIABLE TO CHECK IF MERGING IS FINISHED
		select count(*) from tfn.simplify_level4_node into next_node;

		nodes_to_merge := next_node;

	end loop;

end;
$$;

--THE MERGED GEOMETRY WILL HAVE A 0 SPATIAL REF, SO RESET IT TO BNG
update tfn.simplify_level2 set geometry = st_setsrid(geometry,27700) where st_srid(geometry) = 0;

--NOW THAT THE MERGING IS FINISHED, TEST FOR ANY LINKS THAT MAY HAVE BEEN MERGED BY ACCIDENT
do
$$
declare nodes_to_check int := 1;
		merge_nodes_to_check int := 1;
begin
while (nodes_to_check > 0) loop

	--FUNCTION CALL TO DO THE NODE COUNT CHECKS READY FOR THE MERGING TEST
	perform node_checks();
	
	drop table tfn.erroneous_merging;
	create table tfn.erroneous_merging as
	       --read in links and sources from the processed data and count the number of times their nodes appear
	  with erroneous_merging1 AS (
			select a.id, a.source, c.source_count, a.target, d.source_count as target_count, a.geometry 
			  from tfn.simplify_level2 a, tfn.lsoa b, tfn.simplify_level4 c, tfn.simplify_level4 d
			 where b.lsoa21cd = (select * from tfn.next_lsoa_id) and st_dwithin(a.geometry,b.geom,0)
	  		   and a.source = c.source and a.target = d.source),
	  	   --pullout ones where the source count is 1
 	       erroneous_merging2 AS (
			select a.id, a.source, b.geom 
			  from erroneous_merging1 a, tfn.node_table b 
			 where a.source_count = 1 and a.source = b.nodeid),
 	       --pullout ones where the target count is 1
 		   erroneous_merging3 AS (
			select a.id, a.target, b.geom 
		 	  from erroneous_merging1 a, tfn.node_table b 
			 where a.target_count = 1 and a.target = b.nodeid),
 		   --get the distance from the source nodes to the nearest link that isn't the one its from
 		   erroneous_merging4 AS (
		    select a.id, a.source, min(st_distance(a.geom,b.geometry)) as dist from erroneous_merging2 a, tfn.simplify_level2 b 
			 where st_dwithin(a.geom,b.geometry,50) and a.id != b.id group by a.id, a.source),
 		   --and repeat for the target nodes
 		   erroneous_merging5 AS (
			select a.id, a.target, min(st_distance(a.geom,b.geometry)) as dist from erroneous_merging3 a, tfn.simplify_level2 b 
			 where st_dwithin(a.geom,b.geometry,50) and a.id != b.id group by a.id, a.target),
 		   --union those 2 sets of results together
 		   erroneous_merging6 AS (
		    select a.id, a.source, b.geom from erroneous_merging4 a, tfn.node_table b 
 			 where a.dist = 0 and a.source = b.nodeid union 
			select a.id, a.target, b.geom from erroneous_merging5 a, tfn.node_table b
 			 where a.dist = 0 and a.target = b.nodeid)
 		--extract the ones where the node intersects another link but not at one of its ends
		select a.id, a.source, a.geom, b.id as merged_id, b.original_ids, b.geometry
			  from erroneous_merging6 a, tfn.simplify_level2 b
			 where st_dwithin(a.geom,b.geometry,0) and a.id != b.id;

	--THESE STEPS GET RID OF SOME FALSE POSITIVES
	delete from tfn.erroneous_merging where merged_id in (select a.id from tfn.simplify_level2 a, tfn.stops_gtfs2 b where a.source = a.target and st_dwithin(a.geometry,b.geom,3));

	--REMOVING 'ISLAND' links that don't connect to anything
  --MAKE SURE TO IGNORE TRUNK LINKS, THEIR SIZE CAN SOMETIMES MEAN THEY CAN APPEAR TO BE ISLAND LINKS WHEN NOT
	drop table tfn.lonely_links;
	create table tfn.lonely_links as
		--read in links that are within a 100m buffer of the lsoa being processed
	  with lonely_links1 AS (
   			select a.id, a.source, a.target from tfn.simplify_level2 a, tfn.lsoa b where a.highway != 'trunk' and b.lsoa21cd = (select * from tfn.next_lsoa_id) and st_dwithin(a.geometry,b.geom,100)),
	  	--connect up the source counts for those links
     	   lonely_links2 AS (
			select a.id, a.source, b.source_count, a.target, c.source_count as target_count
			from lonely_links1 a, tfn.simplify_level4 b, tfn.simplify_level4 c
			where a.source = b.source and a.target = c.source)
    --find the ones that have no connecting links at either end
	select * from lonely_links2 where source_count = 1 and target_count = 1;

	--remove any links from the processing table that were found above
	delete from tfn.simplify_level2 where id in (select id from tfn.lonely_links);

	--CLEAR OUT LOOP LINKS
	--this looks for any links that have an identical source and target node, and that the link isn't one that is closest to a bus stop, then removes them
	delete from tfn.simplify_level2 where source = target and id not in (select a.id from tfn.simplify_level2 a, tfn.stops_gtfs2 b where a.source = a.target and st_dwithin(a.geometry,b.geom,3));

	--this removes any link from the merge checking table that appears in the 'island' links check
	delete from tfn.erroneous_merging where merged_id in (select id from tfn.lonely_links);
	--this is just an extra check to make sure only id's that exist in the processing table are present in the merge checking
	delete from tfn.erroneous_merging where id not in (select id from tfn.simplify_level2);
	--as above, but this time checking the merged_id
	delete from tfn.erroneous_merging where merged_id not in (select id from tfn.simplify_level2);

	select count(*) from tfn.erroneous_merging into nodes_to_check;

	--if there are incorrect merges, order table by id and fix first one, then loop back and recheck merging
	--some situations like roundabouts can have multiple merges to fix but get repaired in one loop
	IF (nodes_to_check > 0) THEN
		--unnest the merged id's for the affected links and reload the originals from the MRN table into the processing one
		insert into tfn.simplify_level2 
		select * from tfn.edge_table where id::text in (select unnest(original_ids) as original_ids from tfn.erroneous_merging
		                                                where id in (select id from tfn.erroneous_merging order by id limit 1));
		--delete the affected links from the processing table
		delete from tfn.simplify_level2 where id in (select merged_id from tfn.erroneous_merging
                                              where id in (select id from tfn.erroneous_merging order by id limit 1));
		--make sure to repopulate the original_ids column for the re-added links
		update tfn.simplify_level2 set original_ids = array[id::text] where original_ids is null;

		--rerun the node counts, but this time using what is picked up in the merging errors table
		drop table tfn.simplify_level3;
		create table tfn.simplify_level3 as
		select source, count(source) as source_count from tfn.simplify_level2 
		 where source in (select source from tfn.edge_table where id::text in (select unnest(original_ids) from tfn.erroneous_merging))
   			or source in (select target from tfn.edge_table where id::text in (select unnest(original_ids) from tfn.erroneous_merging)) group by source;

		insert into tfn.simplify_level3
		select a.target, count(a.target) as source_count from tfn.simplify_level2 a
		where a.target in (select source from tfn.edge_table where id::text in (select unnest(original_ids) from tfn.erroneous_merging))
		   or a.target in (select target from tfn.edge_table where id::text in (select unnest(original_ids) from tfn.erroneous_merging)) group by a.target;

		drop table tfn.simplify_level4;
		create table tfn.simplify_level4 as
		select source, sum(source_count) as source_count from tfn.simplify_level3 
		 where source not in (select source_to_remove from tfn.oneway_fix_nodes) group by source order by sum(source_count) desc;

		drop table tfn.simplify_level4_node;
		create table tfn.simplify_level4_node as
		select source from tfn.simplify_level4 where source_count = 2 order by source limit 1;

		select count(*) from tfn.simplify_level4_node into merge_nodes_to_check;

		--a further loop to handle sorting out links that already have merged sections
		while (merge_nodes_to_check > 0) loop

			--rerun the node counts, but this time using what is picked up in the merging errors table
			drop table tfn.simplify_level3;
			create table tfn.simplify_level3 as
			select source, count(source) as source_count from tfn.simplify_level2 
			 where source in (select source from tfn.edge_table where id::text in (select unnest(original_ids) from tfn.erroneous_merging))
	   			or source in (select target from tfn.edge_table where id::text in (select unnest(original_ids) from tfn.erroneous_merging)) group by source;

			insert into tfn.simplify_level3
			select a.target, count(a.target) as source_count from tfn.simplify_level2 a
			where a.target in (select source from tfn.edge_table where id::text in (select unnest(original_ids) from tfn.erroneous_merging))
			   or a.target in (select target from tfn.edge_table where id::text in (select unnest(original_ids) from tfn.erroneous_merging)) group by a.target;

			drop table tfn.simplify_level4;
			create table tfn.simplify_level4 as
			select source, sum(source_count) as source_count from tfn.simplify_level3 
			 where source not in (select source_to_remove from tfn.oneway_fix_nodes) group by source order by sum(source_count) desc;

			drop table tfn.simplify_level4_node;
			create table tfn.simplify_level4_node as
			select source from tfn.simplify_level4 where source_count = 2 order by source limit 1;

			select count(*) from tfn.simplify_level4_node into merge_nodes_to_check;

			--MERGE THE LINKS INVOLVED
			with links_to_merge AS (
					select * from tfn.simplify_level2 where source = (select source from tfn.simplify_level4_node) or target = (select source from tfn.simplify_level4_node)),
		 		 next_id_to_use AS (
	    			select max(id) + 1 as id from tfn.simplify_level2),
		 		 id_collecting AS (
					select unnest(original_ids) as original_ids from links_to_merge),
		 		 id_collected AS (
					select array_agg(original_ids) as original_ids from id_collecting),
		 		 roadname_collecting1 AS (
					select regexp_replace(unnest(string_to_array(name,',')),'{','') as roadnames from links_to_merge),
		 		 roadname_collecting2 AS (
	 				select regexp_replace(roadnames,' / ','_') as roadnames from roadname_collecting1),
		 		 roadname_collecting3 AS (
	    			select replace(roadnames,'"','') as roadnames from roadname_collecting2),
		 		 roadname_collecting4 AS (
					select replace(roadnames,'}','') as roadnames from roadname_collecting3),
		 		 roadname_collected AS (
					select array_agg(distinct roadnames) as name from roadname_collecting4),
		 		 foot_collecting1 AS (
					select regexp_replace(unnest(string_to_array(foot,',')),'{','') as foot from links_to_merge),
		 		 foot_collecting2 AS (
	    			select regexp_replace(foot,'}','') as foot from foot_collecting1),
		 		 foot_collected AS (
	    			select array_agg(distinct foot) as foot from foot_collecting2),
		 		 prep_for_merge AS (
					select (select id from next_id_to_use) as id, (select original_ids from id_collected) as original_ids, (select name from roadname_collected) as name, --array_to_string(array_agg(distinct name),',') as name,
	       			(select foot from foot_collected) as foot, array_to_string(array_agg(distinct highway),',') as highway,
		   			array_to_string(array_agg(distinct railway),',') as railway, array_to_string(array_agg(distinct rail),',') as rail,
			   	    array_to_string(array_agg(distinct ferry),',') as ferry, array_to_string(array_agg(distinct toll),',') as toll,
		   			array_to_string(array_agg(distinct junction),',') as junction, array_to_string(array_agg(distinct route),',') as route,
		   			array_to_string(array_agg(distinct ford),',') as ford, array_to_string(array_agg(distinct bridge),',') as bridge,
		   			array_to_string(array_agg(distinct tunnel),',') as tunnel, array_to_string(array_agg(distinct service),',') as service,
		   			array_to_string(array_agg(distinct oneway),',') as oneway, sum(length) as length, sum(cost) as cost,
		   			sum(reverse_cost) as reverse_cost, st_astext(st_linemerge(st_collect(st_setsrid(geometry,27700)))) as geom from links_to_merge),
		 		 endpoints AS (
		   			select st_setsrid(st_startpoint(geom),27700) as startpos, st_setsrid(st_endpoint(geom),27700) as endpos from prep_for_merge),
		 		 newsource AS (
		   			select a.startpos, b.nodeid from endpoints a, tfn.node_table_lsoa b where st_dwithin(a.startpos,b.geom,0) and b.nodeid in (select source from tfn.simplify_level4)),
		 		 newtarget AS (
	       			select a.endpos, b.nodeid from endpoints a, tfn.node_table_lsoa b where st_dwithin(a.endpos,b.geom,0) and b.nodeid in (select source from tfn.simplify_level4)),
		 		 newrecord AS (
		   			insert into tfn.simplify_level2
		   			select a.id, a.name, a.foot, a.highway, a.railway, a.rail, a.ferry, a.toll, a.junction, a.route, a.ford, a.bridge, a.tunnel, a.service,
		          		a.oneway, a.length, b.nodeid as source, c.nodeid as target, a.cost, a.reverse_cost, a.geom, a.original_ids
		     		from prep_for_merge a, newsource b, newtarget c)
			delete from tfn.simplify_level2 where id in (select id from links_to_merge);

			update tfn.simplify_level2 set geometry = st_setsrid(geometry,27700) where st_srid(geometry) = 0;

		end loop;

    ELSE select count(*) from tfn.erroneous_merging into nodes_to_check;
	END IF;

	end loop;
end;
$$;

--THIS SECTION CHECKS FOR LINKS THAT HAVE BEEN MERGED, BUT THAT SHOULD BE A JUNCTION INSTEAD
do
$$
declare nodes_to_check int := 1;
		merge_nodes_to_check int := 1;
begin
	drop table tfn.simplify_level3;
	create table tfn.simplify_level3 as
	select source, count(source) as source_count from tfn.simplify_level2 where source != target group by source;

	insert into tfn.simplify_level3
	select target, count(target) as source_count from tfn.simplify_level2 where target != source group by target;

	drop table tfn.simplify_level4;
	create table tfn.simplify_level4 as
	select source, sum(source_count) as source_count from tfn.simplify_level3 
	 where source not in (select source_to_remove from tfn.oneway_fix_nodes) group by source order by sum(source_count) desc;
	--select * from tfn.simplify_level4 where source = 500446875;
	drop table tfn.simplify_level4_node;
	create table tfn.simplify_level4_node as
	select source from tfn.simplify_level4 where source in (select a.nodeid from tfn.node_table a, tfn.lsoa b where b.lsoa21cd = (select * from tfn.next_lsoa_id) and st_dwithin(a.geom,b.geom,0)) and source_count = 2 order by source limit 1;
	
	drop table tfn.erroneous_intersections;
	create table tfn.erroneous_intersections as
			--find links that are intersecting each other within the lsoa being worked on
	  with erroneous_intersections as (
			select a.id as id1, a.source as source1, a.target as target1, a.original_ids as original_ids1, 
		       b.id as id2, b.source as source2, b.target as target2, b.original_ids as original_ids2, st_intersection(a.geometry,b.geometry) as int_geom
			  from tfn.simplify_level2 a, tfn.simplify_level2 b, tfn.lsoa c
			 where c.lsoa21nm in (select * from tfn.next_lsoa_name)
			  and st_dwithin(a.geometry, c.geom, 0)
			  and st_dwithin(b.geometry, c.geom, 0)
			  and a.id != b.id and st_dwithin(a.geometry,b.geometry,0)),
	  		--select these and join up with the node table
		   erroneous_intersections2 as (
			select id1, source1, target1, source2, target2, original_ids1, id2, original_ids2, int_geom, nodeid from erroneous_intersections, tfn.node_table where st_dwithin(int_geom,geom,0))
		    --find the intersections that don't have a nodeid that appears in the node check counts
	select * from erroneous_intersections2 where (nodeid not in (select source from tfn.simplify_level4) or (source1 != source2 and source1 != target2 and target1 != source2 and target1 != target2));

	--delete intersections where they involve oneway fix nodes
	delete from tfn.erroneous_intersections where nodeid in (select source_to_remove from tfn.oneway_fix_nodes);

	select count(*) from tfn.erroneous_intersections into nodes_to_check;

	IF (nodes_to_check > 0) THEN
		--check the intersections table for cases where more than one link intersects a wrongly merged link
		with more_than_two_links1 as (select id1, id2 from tfn.erroneous_intersections order by id1 limit 1),
	 		 more_than_two_links2 as (select a.* from tfn.erroneous_intersections a, more_than_two_links1 b
							   		   where (a.id1,a.id2) not in (select id1,id2 from more_than_two_links1)
										 and ((a.id1 = b.id1 and a.id2 != b.id2) or (a.id1 = b.id2 and a.id2 != b.id1)) order by a.id1),
			 more_than_two_links3 as (select a.id1, a.original_ids1 as original_ids from more_than_two_links2 a, more_than_two_links1 b where a.id1 != b.id1 and a.id1 != b.id2
									   union
									  select a.id2, a.original_ids2 as original_ids from more_than_two_links2 a, more_than_two_links1 b where a.id2 != b.id1 and a.id2 != b.id2)
		insert into tfn.more_than_two_links select * from more_than_two_links3;

		--insert into the processing table the original MRN links that made up the affected links
		insert into tfn.simplify_level2 
		select * from tfn.edge_table where id::text in (select unnest(original_ids1) as original_ids from tfn.erroneous_intersections
		                                                where id1 in (select id1 from tfn.erroneous_intersections order by id1 limit 1)
														  and array_length(original_ids1, 1) > 1
														union
														select unnest(original_ids2) as original_ids from tfn.erroneous_intersections
														 where id1 in (select id1 from tfn.erroneous_intersections order by id1 limit 1)
														   and array_length(original_ids2, 1) > 1);
		--insert any extra links that make up the junction back into the processing table
		insert into tfn.simplify_level2
		select * from tfn.edge_table where id::text in (select unnest(original_ids) as original_ids from tfn.more_than_two_links
			                                                 where array_length(original_ids, 1) > 1);

		--clear out the affected links from the processing table
		delete from tfn.simplify_level2 where id in (select id1 from tfn.erroneous_intersections where id1 in (select id1 from tfn.erroneous_intersections order by id1 limit 1)
		                                                                                           and array_length(original_ids1, 1) > 1
		                                             union
													 select id2 from tfn.erroneous_intersections where id1 in (select id1 from tfn.erroneous_intersections order by id1 limit 1)
													                                               and array_length(original_ids2, 1) > 1);
		delete from tfn.simplify_level2 where id in (select id1 from tfn.more_than_two_links where array_length(original_ids, 1) > 1);

		update tfn.simplify_level2 set original_ids = array[id::text] where original_ids is null;

		perform multi_merge_checks();

		select count(*) from tfn.simplify_level4_node into merge_nodes_to_check;

		while (merge_nodes_to_check > 0) loop
			--read in the links that match the merge node
			with links_to_merge AS (select * from tfn.simplify_level2 where source = (select source from tfn.simplify_level4_node) or target = (select source from tfn.simplify_level4_node)),
				--get the max id from the processing table and add 1 to assign to the new merged feature
		 		 next_id_to_use AS (select max(id) + 1 as id from tfn.simplify_level2),
		 		--unnest the array of original id's to cover situations where a link is already merged
		 		 id_collecting AS (select unnest(original_ids) as original_ids from links_to_merge),
		 		--collect everything up into a new array for the new merged feature
		 		 id_collected AS (select array_agg(original_ids) as original_ids from id_collecting),
		 		--unnest all the roadnames involved and get rid of special characters, then regroup into a new merged roadname
		 		 roadname_collecting1 AS (select regexp_replace(unnest(string_to_array(name,',')),'{','') as roadnames from links_to_merge),
		 		 roadname_collecting2 AS (select regexp_replace(roadnames,' / ','_') as roadnames from roadname_collecting1),
		 		 roadname_collecting3 AS (select replace(roadnames,'"','') as roadnames from roadname_collecting2),
		 		 roadname_collecting4 AS (select replace(roadnames,'}','') as roadnames from roadname_collecting3),
		 		 roadname_collected AS (select array_agg(distinct roadnames) as name from roadname_collecting4),
		 		--then repeat for footpaths
		 		 foot_collecting1 AS (select regexp_replace(unnest(string_to_array(foot,',')),'{','') as foot from links_to_merge),
		 		 foot_collecting2 AS (select regexp_replace(foot,'}','') as foot from foot_collecting1),
		 		 foot_collected AS (select array_agg(distinct foot) as foot from foot_collecting2),
		 		--do all the aggregating on attributes ready for the newly merged feature
		 		 prep_for_merge AS (select (select id from next_id_to_use) as id, (select original_ids from id_collected) as original_ids, (select name from roadname_collected) as name,
	   							   (select foot from foot_collected) as foot, array_to_string(array_agg(distinct highway),',') as highway,
	   							   array_to_string(array_agg(distinct railway),',') as railway, array_to_string(array_agg(distinct rail),',') as rail,
		   						   array_to_string(array_agg(distinct ferry),',') as ferry, array_to_string(array_agg(distinct toll),',') as toll,
		   						   array_to_string(array_agg(distinct junction),',') as junction, array_to_string(array_agg(distinct route),',') as route,
								   array_to_string(array_agg(distinct ford),',') as ford, array_to_string(array_agg(distinct bridge),',') as bridge,
		   						   array_to_string(array_agg(distinct tunnel),',') as tunnel, array_to_string(array_agg(distinct service),',') as service,
								   array_to_string(array_agg(distinct oneway),',') as oneway, sum(length) as length, sum(cost) as cost,
								   sum(reverse_cost) as reverse_cost, st_astext(st_linemerge(st_collect(st_setsrid(geometry,27700)))) as geom from links_to_merge),
		 		--get the endpoints of the new feature
		 		 endpoints AS (select st_setsrid(st_startpoint(geom),27700) as startpos, st_setsrid(st_endpoint(geom),27700) as endpos from prep_for_merge),
		 		--take the source endpoint and match it to the MRN node table 
		 		 newsource AS (select a.startpos, b.nodeid from endpoints a, tfn.node_table_lsoa b where st_dwithin(a.startpos,b.geom,0) and b.nodeid in (select source from tfn.simplify_level4)),
		 		--take the target endpoint and match it to the MRN node table
				 newtarget AS (select a.endpos, b.nodeid from endpoints a, tfn.node_table_lsoa b where st_dwithin(a.endpos,b.geom,0) and b.nodeid in (select source from tfn.simplify_level4)),
				--insert the new feature into the processing table
				 newrecord AS (insert into tfn.simplify_level2
							   select a.id, a.name, a.foot, a.highway, a.railway, a.rail, a.ferry, a.toll, a.junction, a.route, a.ford, a.bridge, a.tunnel, a.service,
							          a.oneway, a.length, b.nodeid as source, c.nodeid as target, a.cost, a.reverse_cost, a.geom, a.original_ids
							     from prep_for_merge a, newsource b, newtarget c)
				--delete the old features found in the intersection test
			delete from tfn.simplify_level2 where id in (select id from links_to_merge);

			--update the spatial reference for the new feature
			update tfn.simplify_level2 set geometry = st_setsrid(geometry,27700) where st_srid(geometry) = 0;

			perform multi_merge_checks();
			select count(*) from tfn.simplify_level4_node into merge_nodes_to_check;
		end loop;
	ELSE select count(*) from tfn.erroneous_intersections into nodes_to_check;
	END IF;
end;
$$;


--LASTLY, FIX ANY OF THOSE ONEWAY ISSUES DETECTED EARLIER
do
$$
declare oneways_to_fix int := 1;
begin
	--check the row count from the oneway fix table, if 0 then exit
	select count(*) from tfn.oneway_fix_nodes into oneways_to_fix;
	while (oneways_to_fix > 0) loop
			--get the two links involved that are attached to the oneway node in the fix table
		with oneway_fixing1 as (select * from tfn.simplify_level2 where source in (select source_to_remove from tfn.oneway_fix_nodes order by source_to_remove limit 1)
								union
								select * from tfn.simplify_level2 where target in (select source_to_remove from tfn.oneway_fix_nodes order by source_to_remove limit 1)),
			--take the link with the longest length to use as the one to assign the directionality with
			 oneway_fixing2 as (select id, oneway from oneway_fixing1 order by length desc limit 1),
			--check the count of distinct oneway attributes from the first step
			 oneway_fixing2_count as(select count(distinct oneway) as oneway_count from oneway_fixing1),
			--do checks to work out which cost to use
			 oneway_fixing3 as (select id, case when (select oneway_count from oneway_fixing2_count) = 2 then cost else reverse_cost end as reverse_cost_to_use, 
						    			   case when (select oneway_count from oneway_fixing2_count) = 2 then reverse_cost else cost end as cost_to_use from oneway_fixing1 order by length limit 1),
			--assign the next cost to the id
			 oneway_fixing4 as (select a.id, b.oneway, a.reverse_cost_to_use, a.cost_to_use from oneway_fixing3 a, oneway_fixing2 b)
			--update the link in the processing table with the new costs and directionality
		update tfn.simplify_level2 set (cost, reverse_cost, oneway) = (select cost_to_use, reverse_cost_to_use, oneway from oneway_fixing4)
	 	 where id in (select id from oneway_fixing4);

	 	 	--now take the updated links from the processing table and merge usng the node from the oneway fix table
	 	with links_to_merge as (select * from tfn.simplify_level2 where source = (select source_to_remove from tfn.oneway_fix_nodes order by source_to_remove limit 1) or target = (select source_to_remove from tfn.oneway_fix_nodes order by source_to_remove limit 1)),
	 		--find out the next id available to use
			 next_id_to_use as (select max(id) + 1 as id from tfn.simplify_level2),
			--extract the original id's incase the features involved have already been merged before
		     id_collecting AS (select unnest(original_ids) as original_ids from links_to_merge),
		    --collect all of those up into a new array of ids for the new feature
			 id_collected AS (select array_agg(original_ids) as original_ids from id_collecting),
			--sort out the roadnames for these
	 		 roadname_collecting1 AS (select regexp_replace(unnest(string_to_array(name,',')),'{','') as roadnames from links_to_merge),
			 roadname_collecting2 AS (select regexp_replace(roadnames,' / ','_') as roadnames from roadname_collecting1),
			 roadname_collecting3 AS (select replace(roadnames,'"','') as roadnames from roadname_collecting2),
			 roadname_collecting4 AS (select replace(roadnames,'}','') as roadnames from roadname_collecting3),
			 roadname_collected AS (select array_agg(distinct roadnames) as name from roadname_collecting4),
			--and repeat for the foot attribute
			 foot_collecting1 AS (select regexp_replace(unnest(string_to_array(foot,',')),'{','') as foot from links_to_merge),
			 foot_collecting2 AS (select regexp_replace(foot,'}','') as foot from foot_collecting1),
			 foot_collected AS (select array_agg(distinct foot) as foot from foot_collecting2),
			--run the aggregation for the links that make up the merge
			 prep_for_merge AS (select (select id from next_id_to_use) as id, (select original_ids from id_collected) as original_ids, (select name from roadname_collected) as name,
						       (select foot from foot_collected) as foot, array_to_string(array_agg(distinct highway),',') as highway,
							   array_to_string(array_agg(distinct railway),',') as railway, array_to_string(array_agg(distinct rail),',') as rail,
							   array_to_string(array_agg(distinct ferry),',') as ferry, array_to_string(array_agg(distinct toll),',') as toll,
							   array_to_string(array_agg(distinct junction),',') as junction, array_to_string(array_agg(distinct route),',') as route,
							   array_to_string(array_agg(distinct ford),',') as ford, array_to_string(array_agg(distinct bridge),',') as bridge,
	   						   array_to_string(array_agg(distinct tunnel),',') as tunnel, array_to_string(array_agg(distinct service),',') as service,
							   array_to_string(array_agg(distinct oneway),',') as oneway, sum(length) as length, sum(cost) as cost,
							   sum(reverse_cost) as reverse_cost, st_linemerge(st_collect(geometry)) as geom from links_to_merge),
			--get the endpoints for the newly merged feature
			 endpoints AS (select st_startpoint(geom) as startpos, st_endpoint(geom) as endpos from prep_for_merge),
			--match the startpoint to the node table
			 newsource AS (select a.startpos, b.nodeid from endpoints a, tfn.node_table_lsoa b where st_dwithin(a.startpos,b.geom,0)),
			--match the endpoint to the node table
			 newtarget AS (select a.endpos, b.nodeid from endpoints a, tfn.node_table b where st_dwithin(a.endpos,b.geom,0)),
			--insert the newly merged feature into the processing table
			 newrecord AS (insert into tfn.simplify_level2
			 			   select a.id, a.name, a.foot, a.highway, a.railway, a.rail, a.ferry, a.toll, a.junction, a.route, a.ford, a.bridge, a.tunnel, a.service,
						          a.oneway, a.length, b.nodeid as source, c.nodeid as target, a.cost, a.reverse_cost, a.geom, a.original_ids
						     from prep_for_merge a, newsource b, newtarget c)
			--delete the old links from the processing table
		delete from tfn.simplify_level2 where id in (select id from links_to_merge);

		--remove the node that's been resolved from the oneway fix table
		delete from tfn.oneway_fix_nodes where source_to_remove in (select source_to_remove from tfn.oneway_fix_nodes order by source_to_remove limit 1);

		--check how many rows are left in the oneway fix table
		select count(*) from tfn.oneway_fix_nodes into oneways_to_fix;
	end loop;
end;
$$;

----recreate the full table from the processing one
--drop table tfn.simplify_level_full;
--create table tfn.simplify_level_full as
--select distinct * from tfn.simplify_level2;
----add the rowid column into the full table
--alter table tfn.simplify_level_full add column rowid serial;
--clear out the oneway fix table in case it isn't already
--truncate table tfn.oneway_fix_nodes;
--truncate table tfn.oneway_avoid_nodes;
--truncate table tfn.more_than_two_links;

----I use this to populate a table to keep track of what LSOA's are complete
--insert into tfn.lsoa_complete select geom from tfn.lsoa where lsoa21cd in (select * from tfn.next_lsoa_id);