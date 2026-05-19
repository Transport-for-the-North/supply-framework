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
6. Finally, add QGIS bin folder (`C:\Program Files\QGIS {version}\bin`) to the PATH environment
   variable in your account.
