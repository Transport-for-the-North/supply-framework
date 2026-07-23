# supply-framework

PostGIS based transport supply framework.

## Setup Local PostGresSQL Server

Install PostGreSQL server locally and connect to the database,
it should be accessible within pgAdmin with:

- Host: localhost
- Port: 5432

### Install PostGIS Extension

Install PostGIS database extensions with Application Stack Builder (search in Start Menu),
tick setup postgresql server and install GDAL.

1. Open Application Stack Builder (search in Windows Start Menu)
2. Select your local database server
3. Select Spatial Extensions > PostGIS 3.6
4. Download extensions to your downloads folder, then click next to start installation
5. Click through the PostGIS installation window
    - Enable "Create spatial database" to create a sample database in your local server
    - Enable "Enable All GDAL Drivers"

### Enable Extensions

Once extensions are installed, enable them in the database, with the following SQL queries.

```sql
CREATE EXTENSION postgis;
CREATE EXTENSION pgrouting;
```

## Add Database to QGIS

1. Open the Data Source Manager in QGIS (Layer > Data Source Manager)
2. Add a new PostgreSQL connection:
    - Name: whatever you like
    - Host: localhost
    - Port: 5432
    - Database: name of the database to connect to
3. Add an authentication configuration with the username and password to connect to your local
   database, should just be a "Basic authentication".
4. Click "Test Connection"
5. Open DB Manager (Database > DB Manager) to check your new database connection is visible and use
   it to view / import tables from the database directly into QGIS.

### QGIS CLI Tools

QGIS comes with some command-line tools for interacting with PostGIS, GDAL and others, these are contained
within the QGIS install location in a bin sub-folder usually `C:\Program Files\QGIS {version}\bin`. The QGIS bin
folder might want to be added to the PATH environment variable by either:

1. Add the folder to the account level PATH environment variable (**not recommended** as it can cause issues with other packages)
2. Set the PATH environment variable within a single command-line instance with `set PATH="C:\Program Files\QGIS {version}\bin";%PATH%`

> [!WARNING]
> Other tools / packages which use GDAL (e.g. geopandas, fiona) can be unusable if the QGIS bin
> folder is added to the account wide PATH environment variable.
