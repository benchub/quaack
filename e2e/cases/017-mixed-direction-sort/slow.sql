SELECT player_id, score, achieved_at
FROM public.scores
WHERE game_id = 3
ORDER BY score DESC, achieved_at, id
LIMIT 10;
