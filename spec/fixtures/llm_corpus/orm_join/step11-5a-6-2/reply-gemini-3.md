```json
{
  "indexes": [
    "CREATE INDEX ON public.users USING btree (country, id) INCLUDE (email) WHERE name IS NOT NULL"
  ]
}

```
