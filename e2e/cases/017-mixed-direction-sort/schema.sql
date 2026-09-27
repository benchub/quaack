-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.scores (
    id           bigint PRIMARY KEY,
    game_id      integer NOT NULL,
    player_id    integer NOT NULL,
    score        integer NOT NULL,
    achieved_at  timestamptz NOT NULL
);

INSERT INTO public.scores (id, game_id, player_id, score, achieved_at)
SELECT i, 1 + i % 20, (i * 7) % 90000, (i::bigint * 7919) % 100000,
       timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute'
FROM generate_series(1, 600000) AS i;

CREATE INDEX scores_game_id_idx ON public.scores (game_id);
VACUUM ANALYZE;
