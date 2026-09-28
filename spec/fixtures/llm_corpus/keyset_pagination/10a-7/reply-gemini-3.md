{
"inserts": [
"INSERT INTO public.orders (id, user_id, status, total_cents, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES (CAST($2 AS bigint), 1, 'pending', 100, $1, $1), (CAST($2 AS bigint) - 1, 1, 'pending', 100, $1, $1), (CAST($2 AS bigint) + 1, 1, 'pending', 100, $1, $1), (CAST($2 AS bigint) - 2, 1, 'pending', 100, CAST('1970-01-01 00:00:00Z' AS timestamp with time zone), CAST('1970-01-01 00:00:00Z' AS timestamp with time zone)), (CAST($2 AS bigint) + 2, 1, 'pending', 100, CAST('1970-01-01 00:00:00Z' AS timestamp with time zone), CAST('1970-01-01 00:00:00Z' AS timestamp with time zone)), (CAST($2 AS bigint) - 3, 1, 'pending', 100, CAST('2038-01-01 00:00:00Z' AS timestamp with time zone), CAST('2038-01-01 00:00:00Z' AS timestamp with time zone));"
]
}
