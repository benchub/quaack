SELECT player_id, score
FROM public.scores
WHERE game_id = 3
ORDER BY score DESC
FETCH FIRST 10 ROWS WITH TIES;
