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