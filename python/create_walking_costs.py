"""Script to create walking costs using the MRN for a localisation zoning system."""

# Workflow:
# 1. Get centroids for all Cumbia (internal OAs), check these with the localisation zoning system
#   1.1. Probably want to start with only Cumbria first, think about the other areas later
# 2. Spatial join to find nearest node from MRN for each centroid
# 3. Do the isochrone thing for each node per centroid

##### IMPORTS #####

import logging
import pathlib
import pydantic
import functools

from pydantic import dataclasses
import geopandas as gpd
import pandas as pd
import sqlalchemy

from shapely import wkb
                                                       
import caf.toolkit as ctk

##### CONSTANTS #####s

_NAME = pathlib.Path(__file__).stem
LOG = logging.getLogger(_NAME)
_CONFIG_FILE = pathlib.Path(__file__).with_suffix(".yml")

##### CLASSES & FUNCTIONS #####

@dataclasses.dataclass
class GeoFile:
    """Class to store information needed for geodata from a shapefile."""

    name: str
    path: pathlib.Path
    id_col: str

    def validate(self) -> None:
        """Check the file contains the id column."""
        if not self.path.is_file():
            raise FileNotFoundError(self.path)

        gpd.read_file(self.path, rows=2, columns=self.id_col)

    def read(self) -> gpd.GeoDataFrame:
        """Read the full file."""
        return gpd.read_file(
            self.path,
            engine="pyogrio"
        )
    
@dataclasses.dataclass
class Zones(GeoFile):
    """GeoFile class for the zones shapefile."""

    zone_name_col: str
    zone_system_col: str
    internal_zone_system: str

    @property
    def columns(self) -> list[str]:
        """List of the data columns in the zones shapefile."""
        return [self.id_col, self.zone_name_col, self.zone_system_col]

    def validate(self) -> None:
        """Check the file contains the right columns."""
        if not self.path.is_file():
            raise FileNotFoundError(self.path)

        gpd.read_file(self.path, rows=2, columns=self.columns)

    def internal_zones(self) -> gpd.GeoDataFrame:
        """Filter to internal zones."""
        zones = self.read()
        return zones[zones[self.zone_system_col] == self.internal_zone_system]

@dataclasses.dataclass
class DatabaseConfig:
    """Connection parameters for PostGIS database."""

    username: str
    password: str
    host: str
    database: str
    port: int
    driver: str = "postgresql"

    def create_url(self) -> sqlalchemy.URL:
        """Create database URL from config parameters."""
        return sqlalchemy.URL.create(
            self.driver,
            username=self.username,
            password=self.password,
            host=self.host,
            port=self.port,
            database=self.database,
            query={"application_name": "costs"},
        )

    def create_engine(self, **kwargs) -> sqlalchemy.Engine:
        """Create database engine from given database parameters.

        Parameters
        ----------
        kwargs
            Keyword arguments passed directly to :func:`sqlalchemy.create_engine`.
        """
        plugins = kwargs.pop("plugins", ["geoalchemy2"])

        return sqlalchemy.create_engine(self.create_url(), plugins=plugins, **kwargs)


class _Config(ctk.BaseConfig):
    """Config for running localisation costs script."""

    output_path: pydantic.DirectoryPath
    zones: Zones
    centroids: GeoFile
    database: DatabaseConfig

    @functools.cached_property
    def output_folder(self) -> pathlib.Path:
        """Folder to save outputs to."""
        folder = self.output_path / f"{self.zones.name}_localisation_costs"
        folder.mkdir(exist_ok=True)
        return folder


def create_mrn_costs(
        conn: sqlalchemy.Connection
) -> gpd.GeoDataFrame:
        # Important: the centroids NEED to be at the start or end of an edge for the pgr driving distance function to work

    # Start committing to db
    trans = conn.begin()

    # create table with nodes nearest to centroids (only source or target in edge table)
    node_centroids_query = """
        DROP TABLE IF EXISTS tfn.node_centroids;
        CREATE TABLE tfn.node_centroids AS
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
        """
    conn.execute(sqlalchemy.text(node_centroids_query))

    # Create a subset
#        n = 5
#        subset_query = f"""
#            DROP TABLE IF EXISTS tfn.node_centroids_subset;
#            CREATE TABLE tfn.node_centroids_subset AS
#            SELECT * FROM tfn.node_centroids
#            LIMIT {n};
#        """
#        conn.execute(sqlalchemy.text(subset_query))

    # With SQL
    isochrones_query = """
        DROP TABLE IF EXISTS tfn.test_nodes_join;
        CREATE TABLE tfn.test_nodes_join AS
        SELECT * FROM tfn.node_centroids n
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

        DROP TABLE IF EXISTS tfn.test_nodes_join_select;
        CREATE TABLE tfn.test_nodes_join_select AS
        SELECT 
            a.centroid_id as start_centroid,
            a.node_id as start_node,
            a.node as target_node,
            a.seq,
            a.depth,
            a.start_vid,
            a.pred,
            a.edge,
            a.cost,
            a.agg_cost,
            b.centroid_id as target_centroid,
            b.dist as node_centroid_dist,
            b.geom
        FROM tfn.test_nodes_join a
        INNER JOIN (
            SELECT * FROM tfn.node_centroids
        ) b
        ON a.node = b.node_id;
    """
    conn.execute(sqlalchemy.text(isochrones_query))

    # Commit to db
    trans.commit()

    return gpd.read_postgis(
        sqlalchemy.text("SELECT * FROM tfn.test_nodes_join_select"),
        conn,
        geom_col="geom"
    )

def main() -> None:
    """Create costs for localisation zones."""
    parameters = _Config.load_yaml(_CONFIG_FILE)
    details = ctk.ToolDetails(_NAME, "0.1.0")
    log_file = pathlib.Path(parameters.output_folder / f"{_NAME}.log")

    with ctk.LogHelper(_NAME, details, log_file=log_file):
        LOG.debug("Config\n%s", parameters.to_yaml())

        # Connect to DB
        conn = parameters.database.create_engine().connect()

        # Load data
        # zones = parameters.zones.read()  # full zones
        local_zones = parameters.zones.internal_zones()
        centroids = parameters.centroids.read()

        # Check if there are missing centroids
        attr_join = local_zones.merge(centroids, how="left", left_on=parameters.zones.zone_name_col,
                                      right_on=parameters.centroids.id_col)
        if len(attr_join[attr_join.isna().any(axis=1)]) > 0:
            LOG.info("There are missing centroids from the localised zones.")

        # Filter centroids to internal area
        local_centroids = centroids.merge(local_zones.drop(columns=local_zones.geometry.name), how="inner", left_on=parameters.centroids.id_col,
                                      right_on=parameters.zones.zone_name_col)
        
        # Store the centroids in the postgis db (temporary)
        local_centroids.to_postgis("centroids", conn, if_exists="replace")

        # Create the network costs using mrn (<20kms)
        # mrn_costs = create_mrn_costs(conn)  # uncomment after testing
        mrn_costs = gpd.read_postgis(
                sqlalchemy.text("SELECT * FROM tfn.test_nodes_join_select"),
                conn,
                geom_col="geom"
            )
        
        # comment while testing 

##### MAIN #####
if __name__ == "__main__":
    main()
