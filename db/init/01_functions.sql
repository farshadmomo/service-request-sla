-- SLA due date for a request.
--   P1     = created_at + 4 clock hours (weekends don't matter)
--   P2..P4 = 1 / 3 / 5 business days (Mon-Fri), due at 17:00 Tehran time
--            on the Nth business day after the Tehran-local creation date.
-- Tehran has had no daylight saving time since 2022, so it is always UTC+03:30.
CREATE OR REPLACE FUNCTION sla_due_at(p_created_at timestamptz, p_priority text)
RETURNS timestamptz
LANGUAGE plpgsql
IMMUTABLE STRICT
AS $$
DECLARE
  tz        constant text := 'Asia/Tehran';
  days_left int  := CASE p_priority WHEN 'P2' THEN 1 WHEN 'P3' THEN 3 WHEN 'P4' THEN 5 END;
  d         date := (p_created_at AT TIME ZONE tz)::date;
BEGIN
  IF p_priority = 'P1' THEN
    RETURN p_created_at + interval '4 hours';
  END IF;

  IF days_left IS NULL THEN
    RAISE EXCEPTION 'unknown priority: %', p_priority USING ERRCODE = '22023';
  END IF;

  WHILE days_left > 0 LOOP
    d := d + 1;
    IF extract(isodow FROM d) < 6 THEN  -- isodow: 1 = Mon ... 6 = Sat, 7 = Sun
      days_left := days_left - 1;
    END IF;
  END LOOP;

  RETURN (d + time '17:00') AT TIME ZONE tz;
END $$;

-- Title used to detect duplicates. Two titles count as the same when they only differ in
--   * upper/lower case
--   * spaces and punctuation ("Monthly  sales report!" = "monthly sales report")
--   * Persian keyboard variants: Arabic yeh/kaf vs Persian yeh/kaf,
--     and the half-space (zero-width non-joiner) vs a normal space
CREATE OR REPLACE FUNCTION normalize_title(p_title text)
RETURNS text
LANGUAGE sql
IMMUTABLE STRICT
RETURN btrim(
  regexp_replace(
    lower(translate(p_title, U&'\064A\0643\200C', U&'\06CC\06A9 ')),
    '[[:space:][:punct:]]+', ' ', 'g'
  )
);


-- The one place that decides which statuses count as "still open".
-- Used by the duplicate rule, the SLA indicator and the update trigger.
CREATE OR REPLACE FUNCTION request_is_open(p_status text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE STRICT
RETURN p_status NOT IN ('Completed', 'Resolved', 'Cancelled');
