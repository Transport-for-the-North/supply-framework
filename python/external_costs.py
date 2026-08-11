import numpy as np
import pandas as pd
import geopandas as gpd

wiggle_factor = 1.326145264110206

centroids = gpd.read_file(
    r"D:\normits\data\zones\centroids\cumbria_pop_weighted_centroids.shp"
)
centroids.rename(columns={"cumbria_lo": "centroid_id"}, inplace=True)

all_centroids = centroids[["centroid_id", "geometry"]].set_index("centroid_id")
full_distance_matrix = (
    all_centroids.geometry.apply(all_centroids.distance).sort_index().sort_index(axis=1)
)
full_distance_matrix.index = full_distance_matrix.index.astype(int)
full_distance_matrix.columns = full_distance_matrix.columns.astype(int)

crow_matrix = full_distance_matrix * wiggle_factor
crow_matrix.index = crow_matrix.index.astype(int)
crow_matrix.columns = crow_matrix.columns.astype(int)

internal_matrix = pd.read_csv(
    r"D:\normits\localisation\create_costs\output\cumbria_zones_localisation_costs\internal_combined_cost_matrix_20000_metres.csv"
)

# Use the centroid_id column from the CSV as the row/column labels
internal_ids = internal_matrix["centroid_id"].astype(int).tolist()
internal_matrix = internal_matrix.set_index("centroid_id")
internal_matrix.index = internal_matrix.index.astype(int)
internal_matrix.columns = internal_matrix.columns.astype(int)

external_ids = full_distance_matrix.index.astype(int).tolist()

# Check numbers
# 3427 total nr
# 1744 internal
# 1683 external
# 1683+1744=3427

# Build the combined matrix with the internal block and external block
all_ids = list(
    dict.fromkeys(
        internal_ids
        + [
            centroid_id
            for centroid_id in external_ids
            if centroid_id not in internal_ids
        ]
    )
)
final_matrix = crow_matrix.reindex(index=all_ids, columns=all_ids)

final_matrix.loc[internal_ids, internal_ids] = internal_matrix.loc[
    internal_ids, internal_ids
].to_numpy()

# Check matrix
rounded = final_matrix.round(10)
diff_matrix = rounded - rounded.T
diff = diff_matrix.stack().sum()

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

diag_sum = np.diag(final_matrix).sum()
if diag_sum != 0:
    print("The diagonal (intrazonal costs) should be zero but it is: %s", diag_sum)

# Validation checks
symmetry_error = (final_matrix - final_matrix.T).abs().max().max()
internal_block_match = (
    (
        final_matrix.loc[internal_ids, internal_ids]
        - internal_matrix.loc[internal_ids, internal_ids]
    )
    .abs()
    .max()
    .max()
)
na_count = final_matrix.isna().sum().sum()

print("Matrix shape:", final_matrix.shape)
print("Square index/columns match:", final_matrix.index.equals(final_matrix.columns))
print("Symmetry max difference:", symmetry_error)
print("Internal block max difference:", internal_block_match)
print("NaN count:", na_count)
print("Diagonal sum:", diag_sum)

final_matrix_description = final_matrix.stack().describe()
# Summary Excel
output_folder = r"D:\normits\localisation\create_costs\temp"
summary_path = output_folder + "/summary.xlsx"
with pd.ExcelWriter(summary_path) as writer:
    distance_bin_counts.to_frame(name="count").to_excel(
        writer, sheet_name="distance_bins"
    )
    final_matrix_description.to_frame(name="value").to_excel(
        writer, sheet_name="final_matrix_description"
    )

# Write matrices
internal_matrix.to_csv(output_folder + "/network_matrix.csv")
crow_matrix.to_csv(output_folder + "/crow_matrix.csv")
final_matrix.to_csv(output_folder + "/full_cost_matrix.csv")
