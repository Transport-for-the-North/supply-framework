"""Script to create costs using the MRN for a localisation zoning system.

Workflow:
1. Get centroids (internal OAs), check with the localisation zoning system
2. Spatial join to find nearest node from MRN for each centroid
3. Run pgRouting (isochrones) for each node per centroid
"""

##### IMPORTS #####

import logging
import pathlib
import functools
import warnings

import pydantic
from pydantic import dataclasses
import geopandas as gpd
import pandas as pd
import sqlalchemy

import numpy as np
import matplotlib.pyplot as plt

import caf.toolkit as ctk

##### CONSTANTS #####s

_NAME = pathlib.Path(__file__).stem
LOG = logging.getLogger(_NAME)
_CONFIG_FILE = pathlib.Path(__file__).with_suffix(".yml")


# Filtering where clauses
FOOT = "e.foot <> 'no' AND e.rail = 'no' AND e.highway IS NOT NULL"
CAR = """
e.rail = 'no' AND e.highway IN (
    'motorway',
    'motorway_link',
    'trunk',
    'trunk_link',
    'primary',
    'primary_link',
    'secondary',
    'secondary_link',
    'tertiary',
    'tertiary_link',
    'unclassified',
    'residential'
)
"""


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
        return gpd.read_file(self.path, engine="pyogrio")


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
    mode: str
    zones: Zones
    centroids: GeoFile
    database: DatabaseConfig

    @functools.cached_property
    def output_folder(self) -> pathlib.Path:
        """Folder to save outputs to."""
        folder = self.output_path / f"{self.zones.name}_localisation_costs"
        folder.mkdir(exist_ok=True)
        return folder

    @functools.cached_property
    def mode_params(self) -> dict:
        """Parameters for the given mode."""
        if self.mode == "foot":
            return {
                "distance_cutoff": 20000,
                "network_radius": 20000 * 1.2,
                "where_clause": FOOT,
            }
        if self.mode == "car":
            return {
                "distance_cutoff": 50000,
                "network_radius": 50000 * 1.2,
                "where_clause": CAR,
            }
        if self.mode == "bike":
            return {
                "distance_cutoff": 50000,
                "network_radius": 50000 * 1.2,
                "where_clause": FOOT,
            }
        raise ValueError(f"Unknown mode: {self.mode}")


def write_centroids_to_db(
    zones: Zones, centroids: GeoFile, conn: sqlalchemy.Connection
):
    """Function to write the centroids within the internal zoning area to database."""
    # Load data
    local_zones = zones.internal_zones()
    centroids_gdf = centroids.read()

    # Check if there are missing centroids
    attr_join = local_zones.merge(
        centroids_gdf,
        how="left",
        left_on=zones.zone_name_col,
        right_on=centroids.id_col,
    )
    if len(attr_join[attr_join.isna().any(axis=1)]) > 0:
        LOG.info("There are missing centroids from the localised zones.")

    # Filter centroids to internal area
    local_centroids = centroids_gdf.merge(
        local_zones.drop(columns=local_zones.geometry.name),
        how="inner",
        left_on=centroids.id_col,
        right_on=zones.zone_name_col,
    )

    # Store the centroids in the postgis db (temporary)
    local_centroids.to_postgis(
        f"centroids_{zones.name}", conn, if_exists="replace", schema="tfn"
    )


def create_network_costs(
    mode_params: dict, zone_name: str, conn: sqlalchemy.Connection
) -> gpd.GeoDataFrame:
    """Function to create distance costs on the mrn network.

    It expects a table on the database with OA centroids (population weighted).

    The first query will create a table node_centroids with the nodes nearest to each centroid,
    these must be at the start or end of an edge or they might not be picked up by pgr.

    The second query will run the pgr driving distance function to find the cost/distance to each
    point that is reachable within the distance of the distance_cutoff parameter.
    It uses a subset of the edge table within the network_radius of each node_centroid.
    Then the result is joined back to the node_centroid table to keep only the reachable nodes
    that correspond to an OA centroid.
    """

    # Start committing to db
    trans = conn.begin()

    # Create table with nodes nearest to centroids
    node_centroids_query = f"""
        DROP TABLE IF EXISTS tfn.node_centroids_{zone_name};
        CREATE TABLE tfn.node_centroids_{zone_name} AS
        SELECT
            c.zone_id AS centroid_id,
            n.nodeid AS node_id,
            n.dist,
            n.geom
        FROM tfn.centroids_{zone_name} c
        CROSS JOIN LATERAL (
            SELECT n.nodeid, n.geom, n.geom <-> c.geometry AS dist
            FROM tfn.node_table AS n
            WHERE EXISTS (
                SELECT 1
                FROM tfn.edge_table e
                WHERE (e.source = n.nodeid
                OR e.target = n.nodeid)
                AND {mode_params['where_clause']}
            )
            ORDER BY dist
            LIMIT 1
        ) n;
        """
    conn.execute(sqlalchemy.text(node_centroids_query))

    # Create isochrones
    isochrones_query = f"""
        DROP TABLE IF EXISTS tfn.walking_isochrones_{zone_name};
        CREATE TABLE tfn.walking_isochrones_{zone_name} AS
        SELECT * FROM tfn.node_centroids_{zone_name} n
        CROSS JOIN LATERAL pgr_drivingDistance(
            format('
            SELECT 
                e.id,
                e.source::int4 AS source,
                e.target::int4 AS target,
                e.cost::float8 AS cost,
                e.reverse_cost::float8 AS reverse_cost
            FROM tfn.edge_table e
            WHERE
                {mode_params['where_clause'].replace("'", "''")}
            AND
                st_dwithin(
                    e.geometry,
                    st_geomfromtext(''%s'', %s),
                    {mode_params['network_radius']}
                )',
                ST_AsText(n.geom),
                ST_SRID(n.geom)
                )::text,
            array[n.node_id],
            {mode_params['network_radius']},
            false,
            true) as route;

        DROP TABLE IF EXISTS tfn.walking_isochrones_centroids_{zone_name};
        CREATE TABLE tfn.walking_isochrones_centroids_{zone_name} AS
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
        FROM tfn.walking_isochrones_{zone_name} a
        INNER JOIN (
            SELECT * FROM tfn.node_centroids_{zone_name}
        ) b
        ON a.node = b.node_id;
    """
    conn.execute(sqlalchemy.text(isochrones_query))

    # Commit to db
    trans.commit()

    return gpd.read_postgis(
        f"tfn.walking_isochrones_centroids_{zone_name}",
        conn,
        geom_col="geom",
    )


def create_crowfly_matrix(conn: sqlalchemy.Connection, zone_name: str) -> pd.DataFrame:
    """Create matrix with crow-fly distances using point locations."""
    centroids = gpd.read_postgis(
        sqlalchemy.text(
            f"SELECT centroid_id, geom FROM tfn.node_centroids_{zone_name}"
        ),
        conn,
        geom_col="geom",
        index_col="centroid_id",
    )

    crow_matrix = (
        centroids.geometry.apply(centroids.distance).sort_index().sort_index(axis=1)
    )

    return crow_matrix


def check_reverse_cost(matrix: pd.DataFrame) -> None:
    """Check that the two halves of the matrix are identical (10 decimals)."""
    # Check that costs are the same both ways
    rounded = matrix.round(10)
    diff_matrix = rounded - rounded.T
    diff = diff_matrix.stack().sum()
    if diff != 0:
        LOG.debug("The costs A->B and B->A are not the same when they should be.")


def get_largest_factors(ratio_matrix: pd.DataFrame, n: int = 5) -> pd.DataFrame:
    """Extract the OD pairs with the highest wiggle factor."""
    stack = ratio_matrix.stack().reset_index()
    stack.columns = ["origin", "target", "value"]

    stack["o_min"] = stack[["origin", "target"]].min(axis=1)
    stack["o_max"] = stack[["origin", "target"]].max(axis=1)

    topn = (
        stack[stack["origin"] != stack["target"]]
        .drop_duplicates(["o_min", "o_max"])
        .nlargest(n, "value")
    )

    return topn[["origin", "target", "value"]]


def create_scatterplot(network_matrix: pd.DataFrame, crowfly_matrix: pd.DataFrame, wiggle_factor: float, output_folder: pathlib.Path) -> None:
    """Create a scatterplot comparing the network matrix with the crow-fly matrix."""
    # only where you have real network values
    mask = network_matrix.notna()

    x = crowfly_matrix[mask].stack()
    y = network_matrix[mask].stack()

    plt.scatter(x, y, alpha=0.05)

    # perfect straight-line relationship
    max_val = x.max()
    plt.plot([0, max_val], [0, max_val], color="grey", linestyle="--", label="1:1")

    # your average factor line
    plt.plot(
        [0, max_val],
        [0, max_val * wiggle_factor],
        color="red",
        label=f"factor = {wiggle_factor:.2f}",
    )

    plt.xlabel("Crow-fly distance")
    plt.ylabel("Network distance")
    plt.legend()
    plt.savefig(output_folder / "scatterplot.png")


def calc_wiggle_factor(network_matrix, crow_matrix) -> np.float64:
    """Function to calculate a wiggle factor to apply to the crow-fly distance matrix."""
    ratio_matrix = network_matrix / crow_matrix
    avg_wiggle_factor = ratio_matrix.stack().mean()
    if ratio_matrix.stack().min() < 1:
        raise ValueError(
            "The minimum ratio between mrn matrix and crow-fly matrix is smaller than 1."
        )

    LOG.info(
        "The wiggle factor (mean) is %.2f and the median is %.2f. " \
        "The min is %.2f and the max is %.2f.",
        ratio_matrix.stack().mean(),
        ratio_matrix.stack().median(),
        ratio_matrix.stack().min(),
        ratio_matrix.stack().max(),
    )
    top5 = get_largest_factors(ratio_matrix)
    LOG.info("The largest factors are for the following ID pairs: %s", top5)

    return avg_wiggle_factor


def count_bin_values(final_matrix) -> pd.Series:
    """Function to count values in normits distance bins, write to log file."""
    # Count bins
    bins = [0, 1, 2, 5, 9, 14, 20, final_matrix.stack().max()]
    labels = ["0-1", "1-2", "2-5", "5-9", "9-14", "14-20", ">20"]
    long_matrix = final_matrix.stack()
    distance_bins = pd.cut(
        long_matrix / 1000,
        bins=bins,
        labels=labels,
        include_lowest=True,
    )
    distance_bin_counts = distance_bins.value_counts().sort_index()
    LOG.info("The value counts in each distance bin are: %s", distance_bin_counts)

    return distance_bin_counts


def create_final_matrix(conn, network_matrix, zone_name: str, output_folder):
    """Function to create final cost matrix.

    The final matrix will consist of costs from the network matrix where they exist,
    and crow-fly costs multiplied with a wiggle factor where there are no network costs.
    It writes all matrices and summary statistics to the given output folder.
    It also writes a scatterplot to that folder.

    The crow-fly costs are calculated for internal zones only, using the centroid ids and
    the spatial position of the network nodes linked to the centroids (nearest).
    The function could be adapted to include external zones for crow-fly costs,
    which would require using the centroid positions instead of the network node 
    positions (see module external_costs.py).
    """

    crow_matrix = create_crowfly_matrix(conn, zone_name)

    wiggle_factor = calc_wiggle_factor(network_matrix, crow_matrix)

    # Fill the missing values in mrn_matrix with the estimated distances
    final_matrix = network_matrix.reindex_like(crow_matrix)
    mask = network_matrix.isna()
    final_matrix[mask] = (crow_matrix * wiggle_factor)[mask]

    # Check diagonal for zeros
    diag_sum = np.diag(final_matrix).sum()
    if diag_sum != 0:
        warnings.warn(
            f"The diagonal (intrazonal costs) should be zero but it is: {diag_sum}",
            RuntimeWarning,
            stacklevel=2,
        )

    # Write some stats to excel
    final_matrix_description = final_matrix.stack().describe()
    distance_bin_counts = count_bin_values(final_matrix)
    # Summary Excel
    summary_path = output_folder / "summary.xlsx"
    with pd.ExcelWriter(summary_path) as writer:
        distance_bin_counts.to_frame(name="count").to_excel(
            writer, sheet_name="distance_bins"
        )
        final_matrix_description.to_frame(name="value").to_excel(
            writer, sheet_name="final_matrix_description"
        )

    # Visualisation
    create_scatterplot(network_matrix, crow_matrix, wiggle_factor, output_folder)

    # Meters to kilometers
    network_matrix /= 1000
    crow_matrix /= 1000
    final_matrix /= 1000

    # Write matrices
    network_matrix.to_csv(output_folder / "network_matrix.csv")
    crow_matrix.to_csv(output_folder / "crow_matrix.csv")
    final_matrix.to_csv(output_folder / "internal_combined_cost_matrix.csv")


def main() -> None:
    """Create costs for localisation zones."""
    parameters = _Config.load_yaml(_CONFIG_FILE)
    details = ctk.ToolDetails(_NAME, "0.1.0")
    log_file = pathlib.Path(parameters.output_folder / f"{_NAME}.log")

    with ctk.LogHelper(_NAME, details, log_file=log_file):
        LOG.debug("Config\n%s", parameters.to_yaml())

        # Connect to DB
        engine = parameters.database.create_engine()
        with engine.connect() as conn:
            ## Select centroids and write to db
            write_centroids_to_db(parameters.zones, parameters.centroids, conn)

            ## Create the network costs using mrn (<20kms)
            LOG.info("Creating network costs, this might take several hours.")
            network_costs = create_network_costs(
                parameters.mode_params, parameters.zones.name, conn
            )
            # this takes about 2.5 hrs for Cumbria OA level 20km
            LOG.info("Finished creating network costs.")

            # Network matrix
            network_matrix = (
                network_costs.pivot(
                    index="start_centroid",
                    columns="target_centroid",
                    values="agg_cost",
                )
                .sort_index()
                .sort_index(axis=1)
            )
            check_reverse_cost(network_matrix)

            create_final_matrix(
                conn, network_matrix, parameters.zones.name, parameters.output_folder
            )


##### MAIN #####
if __name__ == "__main__":
    main()
