-------------------------------------------------------------------------------
-- Prepare the BerlinMOD generator using the OSM data from Milano
-------------------------------------------------------------------------------
 
-- We need to convert the resulting data in Spherical Mercator (SRID = 3857)
-- We create two tables for that

DROP TABLE IF EXISTS RoadSegments;
CREATE TABLE RoadSegments(segmentId bigint PRIMARY KEY, name text, 
  osm_id bigint, tag_id integer, segmentLength float, sourceNode bigint, 
  targetNode bigint, source_osm bigint, target_osm bigint, cost_s float,
  reverse_cost_s float, one_way integer, maxSpeedFwd float, maxSpeedBwd float, 
  priority float, segmentGeo geometry);
INSERT INTO RoadSegments(SegmentId, name, osm_id, tag_id, segmentLength, 
  sourceNode, targetNode, source_osm, target_osm, cost_s, reverse_cost_s, 
  one_way, maxSpeedFwd, maxSpeedBwd, priority, segmentGeo)
SELECT gid, name, osm_id, tag_id, length_m, source, target, source_osm,
  target_osm, cost_s, reverse_cost_s, one_way, maxspeed_forward,
  maxspeed_backward, priority, ST_Transform(the_geom, 3857)
FROM ways;

-- The nodes table should contain ONLY the vertices that belong to the largest
-- connected component in the underlying map. Like this, we guarantee that
-- there will be a non-NULL shortest path between any two nodes.
DROP TABLE IF EXISTS Nodes;
CREATE TABLE Nodes(id bigint PRIMARY KEY, osm_id bigint, geom geometry);
INSERT INTO Nodes(id, osm_id, geom)
WITH Components AS (
  SELECT * FROM pgr_strongComponents(
    'SELECT segmentId AS id, sourceNode AS source, targetNode AS target, '
    'segmentLength AS cost, segmentLength * sign(reverse_cost_s) AS reverse_cost '
    'FROM RoadSegments') ),
LargestComponent AS (
  SELECT component, COUNT(*) FROM Components
  GROUP BY component ORDER BY COUNT(*) DESC LIMIT 1),
Connected AS (
  SELECT id, osm_id, the_geom AS geom
  FROM ways_vertices_pgr W, LargestComponent L, Components C
  WHERE W.id = C.node AND C.component = L.component
)
SELECT ROW_NUMBER() OVER (), osm_id, ST_Transform(geom, 3857) AS geom
FROM Connected;

CREATE UNIQUE INDEX Nodes_id_idx ON Nodes USING BTREE(id);
CREATE INDEX Nodes_osm_id_idx ON Nodes USING BTREE(osm_id);
CREATE INDEX Nodes_geom_idx ON NODES USING GiST(geom);

UPDATE RoadSegments R SET
sourceNode = (SELECT id FROM Nodes N WHERE N.osm_id = R.source_osm),
targetNode = (SELECT id FROM Nodes N WHERE N.osm_id = R.target_osm);

-- Delete the edges whose source or target node has been removed
DELETE FROM RoadSegments WHERE sourceNode IS NULL OR targetNode IS NULL;

CREATE INDEX RoadSegments_segmentGeo_index ON RoadSegments USING GiST(segmentGeo);

/*
-- The following were obtained FROM the OSM file extracted on March 26, 2023
SELECT COUNT(*) FROM RoadSegments;
-- 95025
SELECT COUNT(*) FROM Nodes;
-- 80304
*/

-------------------------------------------------------------------------------
-- Get municipalities data to define home and work regions
-------------------------------------------------------------------------------

-- Milanos' municipalities data from the following sources
-- https://it.wikipedia.org/wiki/Municipi_di_Milano#I_nove_municipi

DROP TABLE IF EXISTS Municipalities;
CREATE TABLE Municipalities(MunicipalityId int PRIMARY KEY, 
  MunicipalityName text, Population int, PercPop float, PopDensityKm2 int, 
  NoEnterp int, PercEnterp float);
INSERT INTO Municipalities (MunicipalityId, MunicipalityName, Population, PopDensityKm2, NoEnterp) VALUES
   (1, 'Municipio 1', 99317, 10271, 6460),
   (2, 'Municipio 2', 163731, 13015, 2266),
   (3, 'Municipio 3', 145345, 10214, 1266),
   (4, 'Municipio 4', 165393, 7883, 14204),
   (5, 'Municipio 5', 126837, 4246, 3769),
   (6, 'Municipio 6', 152942, 8367, 1880),
   (7, 'Municipio 7', 176814, 5642, 3436),
   (8, 'Municipio 8 di Milano', 196562, 8287, 1170),
   (9, 'Municipio 9', 190656, 9027, 9304);

UPDATE municipalities SET
      PercPop = round((population::float / (SELECT SUM(population) FROM municipalities))::numeric, 2),
      PercEnterp = round((NoEnterp::float / (SELECT SUM(NoEnterp) FROM municipalities))::numeric, 2);

-- Compute the geometry of the Municipalities from the boundaries in planet_osm_line

DROP TABLE IF EXISTS MunicipalitiesGeo;
CREATE TABLE MunicipalitiesGeo(Name, Geom) AS
SELECT Name, Way
FROM planet_osm_line L
WHERE Name IN ( SELECT MunicipalityName FROM Municipalities );

-- The geometries of the Municipalities are of type Linestring. They need to be
-- converted into polygons.

ALTER TABLE MunicipalitiesGeo ADD COLUMN GeomPoly geometry;
UPDATE MunicipalitiesGeo
SET GeomPoly = ST_MakePolygon(geom);

-- Disjoint components of Ixelles and Saint-Gilles are encoded as two different
-- features. For this reason ST_Union is needed to make a multipolygon
ALTER TABLE Municipalities ADD COLUMN MunicipalityGeo geometry;
UPDATE Municipalities m
SET MunicipalityGeo = (
  SELECT ST_Union(GeomPoly) FROM MunicipalitiesGeo g
  WHERE m.MunicipalityName = g.Name);

CREATE INDEX Municipalities_MunicipalityGeo_idx ON Municipalities 
USING GiST(MunicipalityGeo);

-- Clean up tables
DROP TABLE IF EXISTS MunicipalitiesGeo;

-- Create home/work regions and nodes

DROP TABLE IF EXISTS HomeRegions;
CREATE TABLE HomeRegions(id, priority, weight, prob, cumulProb, geom) AS
SELECT MunicipalityId, MunicipalityId, population, PercPop,
  SUM(PercPop) OVER (ORDER BY MunicipalityId ASC ROWS 
    BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS CumulProb, MunicipalityGeo
FROM Municipalities;

CREATE INDEX HomeRegions_geom_idx ON HomeRegions USING GiST(geom);

DROP TABLE IF EXISTS WorkRegions;
CREATE TABLE WorkRegions(id, priority, weight, prob, cumulProb, geom) AS
SELECT MunicipalityId, MunicipalityId, NoEnterp, PercEnterp,
  SUM(PercEnterp) OVER (ORDER BY MunicipalityId ASC ROWS
    BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS CumulProb, MunicipalityGeo
FROM Municipalities;

CREATE INDEX WorkRegions_geom_idx ON WorkRegions USING GiST(geom);

DROP TABLE IF EXISTS HomeNodes;
CREATE TABLE HomeNodes AS
SELECT T1.*, T2.id AS region, T2.CumulProb
FROM Nodes T1, HomeRegions T2
WHERE ST_Intersects(T2.geom, T1.geom);

CREATE INDEX HomeNodes_id_idx ON HomeNodes USING BTREE (id);

DROP TABLE IF EXISTS WorkNodes;
CREATE TABLE WorkNodes AS
SELECT T1.*, T2.id AS region
FROM Nodes T1, WorkRegions T2
WHERE ST_Intersects(T1.geom, T2.geom);

CREATE INDEX WorkNodes_id_idx ON WorkNodes USING BTREE (id);

-------------------------------------------------------------------------------
-- THE END
-------------------------------------------------------------------------------
