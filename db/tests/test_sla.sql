-- sla_due_at tests, doesn't change any data
-- 2026-09-14 is a monday
DO $$
DECLARE
  c record;
BEGIN
  FOR c IN SELECT * FROM (VALUES
    -- label,                          priority, created,                        expected
    ('P1 ignores weekends',            'P1', '2026-09-18 22:00 Asia/Tehran', '2026-09-19 02:00 Asia/Tehran'),
    ('P2 weekday',                     'P2', '2026-09-14 10:00 Asia/Tehran', '2026-09-15 17:00 Asia/Tehran'),
    ('P2 Friday afternoon -> Monday',  'P2', '2026-09-18 16:00 Asia/Tehran', '2026-09-21 17:00 Asia/Tehran'),
    ('P2 created Saturday -> Monday',  'P2', '2026-09-19 12:00 Asia/Tehran', '2026-09-21 17:00 Asia/Tehran'),
    ('P2 after hours still next day',  'P2', '2026-09-14 18:00 Asia/Tehran', '2026-09-15 17:00 Asia/Tehran'),
    ('P3 spans weekend',               'P3', '2026-09-16 09:00 Asia/Tehran', '2026-09-21 17:00 Asia/Tehran'),
    ('P4 Monday -> next Monday',       'P4', '2026-09-14 09:00 Asia/Tehran', '2026-09-21 17:00 Asia/Tehran'),
    ('P4 created Sunday -> Friday',    'P4', '2026-09-20 11:00 Asia/Tehran', '2026-09-25 17:00 Asia/Tehran'),
    -- different date in utc and tehran, tehran should win
    ('Thu 21:00 UTC is Fri in Tehran', 'P2', '2026-09-17 21:00 UTC',         '2026-09-21 17:00 Asia/Tehran'),
    ('Fri 22:00 UTC is Sat in Tehran', 'P2', '2026-09-18 22:00 UTC',         '2026-09-21 17:00 Asia/Tehran'),
    -- 17:00 tehran = 13:30 utc
    ('17:00 Tehran is 13:30 UTC',      'P2', '2026-09-14 10:00 Asia/Tehran', '2026-09-15 13:30 UTC')
  ) AS t(label, priority, created, expected)
  LOOP
    ASSERT sla_due_at(c.created::timestamptz, c.priority) = c.expected::timestamptz,
      format('%s: got %s, want %s', c.label,
             sla_due_at(c.created::timestamptz, c.priority), c.expected::timestamptz);
  END LOOP;

  -- unknown priority -> error 22023
  BEGIN
    PERFORM sla_due_at(now(), 'P9');
    RAISE EXCEPTION 'unknown priority was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  RAISE NOTICE 'test_sla: all cases passed';
END $$;