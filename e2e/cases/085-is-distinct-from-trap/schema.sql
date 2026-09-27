CREATE TABLE public.issues (
    id       bigint PRIMARY KEY,
    team_id  integer,
    title    text NOT NULL
);

-- 1,000 teams. 5% of issues have no team.
INSERT INTO public.issues (id, team_id, title)
SELECT i, CASE WHEN i % 20 = 0 THEN NULL ELSE 1 + (i / 3) % 1000 END, 'Issue ' || i || repeat(' ', 40)
FROM generate_series(1, 500000) AS i;

CREATE INDEX issues_team_id_idx ON public.issues (team_id);
VACUUM ANALYZE;
