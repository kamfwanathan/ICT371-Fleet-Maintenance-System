-- ICT371 Q8: Transport Fleet Maintenance  (PostgreSQL 14+, pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- (a) Tables
CREATE TABLE vehicles (
  vehicle_id            INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  registration          VARCHAR(15) NOT NULL UNIQUE,
  current_odometer      INT NOT NULL CHECK (current_odometer >= 0),
  last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
  CONSTRAINT ck_service_le_current CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
  trip_id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id),
  trip_on        DATE NOT NULL,
  start_odometer INT NOT NULL CHECK (start_odometer >= 0),
  end_odometer   INT NOT NULL CHECK (end_odometer >= 0)
);
CREATE TABLE service_alerts (
  vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
  km_since_service INT NOT NULL,
  flagged_on       DATE NOT NULL
);

INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
  ('ABC 1234', 12000,  8000),   -- 4,000 km since service
  ('BAD 5678', 20000, 14000),   -- 6,000 km since service (due)
  ('CAE 9012',  5000,  5000);   -- just serviced

-- (d) Trigger: validates and advances the odometer exactly once per trip
CREATE OR REPLACE FUNCTION trg_trip_odometer() RETURNS TRIGGER AS $$
DECLARE v_current INT;
BEGIN
  SELECT current_odometer INTO v_current
  FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle_id %', NEW.vehicle_id;
  END IF;
  IF NEW.start_odometer IS DISTINCT FROM v_current THEN
    RAISE EXCEPTION 'Start odometer % does not match vehicle current odometer %',
      NEW.start_odometer, v_current;
  END IF;
  IF NEW.end_odometer IS NULL OR NEW.end_odometer <= NEW.start_odometer THEN
    RAISE EXCEPTION 'Invalid mileage: end % must be greater than start %',
      NEW.end_odometer, NEW.start_odometer;
  END IF;
  UPDATE vehicles SET current_odometer = NEW.end_odometer WHERE vehicle_id = NEW.vehicle_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trip_odometer();

-- (b) Function
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT) RETURNS BOOLEAN AS $$
DECLARE v_cur INT; v_srv INT;
BEGIN
  SELECT current_odometer, last_service_odometer INTO v_cur, v_srv
  FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle_id %', p_vehicle_id;
  END IF;
  RETURN (v_cur - v_srv) >= 5000;
END;
$$ LANGUAGE plpgsql STABLE;

-- (c) Procedure: inserts the trip only; the trigger moves the odometer
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
    RAISE EXCEPTION 'Unknown vehicle_id %', p_vehicle_id;
  END IF;
  IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
    RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
  END IF;
  INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
  VALUES (p_vehicle_id, COALESCE(p_trip_on, CURRENT_DATE), p_start, p_end);
END;
$$;

-- Six trips through the procedure (trigger already installed)
CALL pr_record_trip(1, CURRENT_DATE - 6, 12000, 12500);
CALL pr_record_trip(1, CURRENT_DATE - 3, 12500, 13200);   -- vehicle 1 now 5,200 km since service
CALL pr_record_trip(2, CURRENT_DATE - 5, 20000, 20300);
CALL pr_record_trip(2, CURRENT_DATE - 2, 20300, 21000);
CALL pr_record_trip(3, CURRENT_DATE - 4,  5000,  5400);
CALL pr_record_trip(3, CURRENT_DATE - 1,  5400,  5900);
-- Tests:
-- CALL pr_record_trip(3, CURRENT_DATE, 100, 200);   -- error: start does not match odometer
-- CALL pr_record_trip(3, CURRENT_DATE, 5900, 5900); -- error: end not greater
-- SELECT fn_service_due(1), fn_service_due(3);      -- true, false

-- (e) View
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due;

-- (f) Index: equality on vehicle, range on date
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);
-- Justification: a vehicle's trip history for a period is one contiguous index range;
-- the equality column leads, the range column follows, and results come out date-ordered.
ANALYZE trips;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM trips
WHERE vehicle_id = 1 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Alert refresh: upsert due vehicles, remove ones no longer due
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
  SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
  FROM vehicles
  WHERE current_odometer - last_service_odometer >= 5000
  ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service,
        flagged_on       = EXCLUDED.flagged_on;

  DELETE FROM service_alerts sa
  USING vehicles v
  WHERE v.vehicle_id = sa.vehicle_id
    AND v.current_odometer - v.last_service_odometer < 5000;
END;
$$;

SELECT cron.schedule('refresh_service_alerts_weekly', '0 6 * * 1',
  $cron$CALL pr_refresh_service_alerts()$cron$);

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;
-- Service vehicle 1, then refresh: its alert is removed
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 1;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;
