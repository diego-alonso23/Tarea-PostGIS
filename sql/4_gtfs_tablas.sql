-- Etapa 4: tablas crudas del GTFS
-- Las columnas deben calzar con las cabeceras de los .txt (cargar.sh lo verifica)

CREATE TABLE gtfs_raw.stops (stop_id text, stop_code text, stop_name text,
  stop_lat double precision, stop_lon double precision, stop_url text,
  wheelchair_boarding text, location_type text, parent_station text, level_id text);
CREATE TABLE gtfs_raw.routes (route_id text, agency_id text, route_short_name text,
  route_long_name text, route_desc text, route_type text, route_url text,
  route_color text, route_text_color text);
CREATE TABLE gtfs_raw.trips (route_id text, service_id text, trip_id text,
  trip_headsign text, direction_id text, shape_id text, trip_short_name text,
  wheelchair_accessible text, bikes_allowed text);
CREATE TABLE gtfs_raw.shapes (shape_id text, shape_pt_lat double precision,
  shape_pt_lon double precision, shape_pt_sequence integer);
CREATE TABLE gtfs_raw.stop_times (trip_id text, arrival_time text, departure_time text,
  stop_id text, stop_sequence integer, pickup_type text, drop_off_type text, timepoint text);
CREATE TABLE gtfs_raw.feed_info (feed_publisher_name text, feed_publisher_url text,
  feed_lang text, feed_start_date text, feed_end_date text, feed_version text);
