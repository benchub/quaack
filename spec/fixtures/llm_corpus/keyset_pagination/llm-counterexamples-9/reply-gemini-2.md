{"inserts": ["INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES (DEFAULT, 1, 'active', 1000, $1, NOW())"]}
