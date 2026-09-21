-- due date for a request
-- P1: created + 4 hours, weekends included
-- P2/P3/P4: 1/3/5 business days (mon-fri) after the created date, due 17:00 tehran time
-- tehran has no DST since 2022 so it's always +03:30
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
    IF extract(isodow FROM d) < 6 THEN  -- 6 = sat, 7 = sun
      days_left := days_left - 1;
    END IF;
  END LOOP;

  RETURN (d + time '17:00') AT TIME ZONE tz;
END $$;

-- title used for the duplicate check
-- ignores case, extra spaces and punctuation ("Monthly  sales report!" = "monthly sales report")
-- arabic/persian yeh and kaf count as the same letter, half-space counts as a space
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


-- open = not completed, resolved or cancelled
-- used by the duplicate index, the sla view and the trigger
CREATE OR REPLACE FUNCTION request_is_open(p_status text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE STRICT
RETURN p_status NOT IN ('Completed', 'Resolved', 'Cancelled');
