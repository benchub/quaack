# System

You're rewriting one slow PostgreSQL query so it runs faster and returns exactly the same rows. You have no database connection. The payload holds only shapes: the query with $n placeholders for its literals, each placeholder's type and shape with estimated and actual row counts, the plan, the schema, and per-column statistics.

Propose up to five rewrites. Each must be one SELECT that returns the same columns, of the same types, in the same order, for every possible data set the schema allows. Use the original's $n placeholders where it uses literals, never a new $n. Only use tables the original uses, schema-qualified, never views. Don't call volatile functions.

For each rewrite, state the transformation you applied, and every assumption it relies on. Only these kinds of assumption are allowed, and a rewrite relying on anything else will be rejected:
- not_null: a column is NOT NULL.
- unique: a set of columns is unique.
- foreign_key: columns reference another table's columns.
- check: a CHECK constraint with exactly this expression.
Each assumption is checked against the catalog, and a rewrite with an unmet one is rejected.

Answer with JSON: {"rewrites": [{"sql": "...", "transformation": "...", "assumptions": [...]}]}.

# User

The payload:

```json
{"type":"rewrite_payload","query":"SELECT o.user_id, count(*) AS order_count, sum(o.total_cents) AS spent FROM public.orders o WHERE o.status = $1 GROUP BY o.user_id HAVING count(*) > $2 ORDER BY spent DESC","placeholders":{"$1":{"type":"text","pattern":null,"elements":null,"est_rows":14133,"actual_rows":14286.0},"$2":{"type":"integer","pattern":null,"elements":null,"est_rows":3557,"actual_rows":0.0}},"plan":[{"Plan":{"Node Type":"Sort","Parallel Aware":false,"Async Capable":false,"Startup Cost":2634.17,"Total Cost":2643.06,"Plan Rows":3557,"Plan Width":24,"Actual Startup Time":9.687,"Actual Total Time":9.688,"Actual Rows":0.0,"Actual Loops":1,"Disabled":false,"Sort Key":["(sum(total_cents)) DESC"],"Sort Method":"quicksort","Sort Space Used":25,"Sort Space Type":"Memory","Shared Hit Blocks":938,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0,"Plans":[{"Node Type":"Aggregate","Strategy":"Hashed","Partial Mode":"Simple","Parent Relationship":"Outer","Parallel Aware":false,"Async Capable":false,"Startup Cost":2291.0,"Total Cost":2424.37,"Plan Rows":3557,"Plan Width":24,"Actual Startup Time":9.669,"Actual Total Time":9.67,"Actual Rows":0.0,"Actual Loops":1,"Disabled":false,"Group Key":["user_id"],"Filter":"(count(*) > $2)","Planned Partitions":0,"HashAgg Batches":1,"Peak Memory Usage":1561,"Disk Usage":0,"Rows Removed by Filter":14286,"Shared Hit Blocks":935,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0,"Plans":[{"Node Type":"Seq Scan","Parent Relationship":"Outer","Parallel Aware":false,"Async Capable":false,"Relation Name":"orders","Alias":"o","Startup Cost":0.0,"Total Cost":2185.0,"Plan Rows":14133,"Plan Width":12,"Actual Startup Time":0.007,"Actual Total Time":6.552,"Actual Rows":14286.0,"Actual Loops":1,"Disabled":false,"Filter":"(status = $1::text)","Rows Removed by Filter":85714,"Shared Hit Blocks":935,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0}]}]},"Planning":{"Shared Hit Blocks":105,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0},"Planning Time":0.17,"Execution Time":9.804}],"schema":{"tables":[["public","orders"],["public","users"]],"ddl":"--\n-- PostgreSQL database dump\n--\n\n\\restrict o26BRGBngrs72RhAdb3WysLA0FubVh8gVi7DYImwpU1KMTHXcgzf6rB6Jo2dgVi\n\n-- Dumped from database version 18.4 (Debian 18.4-1.pgdg13+1)\n-- Dumped by pg_dump version 18.4 (Homebrew)\n\nSET statement_timeout = 0;\nSET lock_timeout = 0;\nSET idle_in_transaction_session_timeout = 0;\nSET transaction_timeout = 0;\nSET client_encoding = 'UTF8';\nSET standard_conforming_strings = on;\nSELECT pg_catalog.set_config('search_path', '', false);\nSET check_function_bodies = false;\nSET xmloption = content;\nSET client_min_messages = warning;\nSET row_security = off;\n\nSET default_tablespace = '';\n\nSET default_table_access_method = heap;\n\n--\n-- Name: orders; Type: TABLE; Schema: public; Owner: -\n--\n\nCREATE TABLE public.orders (\n    id bigint NOT NULL,\n    user_id bigint NOT NULL,\n    status text NOT NULL,\n    total_cents integer NOT NULL,\n    created_at timestamp with time zone NOT NULL,\n    updated_at timestamp with time zone NOT NULL\n);\n\n\n--\n-- Name: orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -\n--\n\nALTER TABLE public.orders ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (\n    SEQUENCE NAME public.orders_id_seq\n    START WITH 1\n    INCREMENT BY 1\n    NO MINVALUE\n    NO MAXVALUE\n    CACHE 1\n);\n\n\n--\n-- Name: users; Type: TABLE; Schema: public; Owner: -\n--\n\nCREATE TABLE public.users (\n    id bigint NOT NULL,\n    email text NOT NULL,\n    name text,\n    country text NOT NULL,\n    status text NOT NULL,\n    created_at timestamp with time zone NOT NULL\n);\n\n\n--\n-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -\n--\n\nALTER TABLE public.users ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (\n    SEQUENCE NAME public.users_id_seq\n    START WITH 1\n    INCREMENT BY 1\n    NO MINVALUE\n    NO MAXVALUE\n    CACHE 1\n);\n\n\n--\n-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.orders\n    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);\n\n\n--\n-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.users\n    ADD CONSTRAINT users_pkey PRIMARY KEY (id);\n\n\n--\n-- Name: orders_user_id_idx; Type: INDEX; Schema: public; Owner: -\n--\n\nCREATE INDEX orders_user_id_idx ON public.orders USING btree (user_id);\n\n\n--\n-- Name: users_email_key; Type: INDEX; Schema: public; Owner: -\n--\n\nCREATE UNIQUE INDEX users_email_key ON public.users USING btree (email);\n\n\n--\n-- Name: orders orders_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.orders\n    ADD CONSTRAINT orders_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);\n\n\n--\n-- PostgreSQL database dump complete\n--\n\n\\unrestrict o26BRGBngrs72RhAdb3WysLA0FubVh8gVi7DYImwpU1KMTHXcgzf6rB6Jo2dgVi\n\n"},"stats":{"tables":[{"schema":"public","name":"orders","columns":[{"name":"id","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null},{"name":"user_id","n_distinct":-0.20034,"null_frac":0.0,"correlation":-0.002108621,"most_common_freqs":null,"most_common_vals":null},{"name":"status","n_distinct":5.0,"null_frac":0.0,"correlation":0.26820508,"most_common_freqs":[0.4327,0.14323333,0.1428,0.14133333,0.13993333],"most_common_vals":["delivered","pending","cancelled","shipped","refunded"]},{"name":"total_cents","n_distinct":-0.4972,"null_frac":0.0,"correlation":-0.004295681,"most_common_freqs":null,"most_common_vals":null},{"name":"created_at","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null},{"name":"updated_at","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null}],"indexes":[{"name":"orders_pkey","definition":"CREATE UNIQUE INDEX orders_pkey ON public.orders USING btree (id)","columns":[]},{"name":"orders_user_id_idx","definition":"CREATE INDEX orders_user_id_idx ON public.orders USING btree (user_id)","columns":[]}],"extended_statistics":[]}]}}
```

# Reply format

Reply with only JSON matching this schema:

```json
{
  "type": "object",
  "properties": {
    "rewrites": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "sql": {
            "type": "string"
          },
          "transformation": {
            "type": "string"
          },
          "assumptions": {
            "type": "array",
            "items": {
              "anyOf": [
                {
                  "type": "object",
                  "properties": {
                    "kind": {
                      "type": "string",
                      "enum": [
                        "not_null"
                      ]
                    },
                    "table": {
                      "type": "string",
                      "description": "schema-qualified, such as public.orders"
                    },
                    "column": {
                      "type": "string"
                    }
                  },
                  "required": [
                    "kind",
                    "table",
                    "column"
                  ],
                  "additionalProperties": false
                },
                {
                  "type": "object",
                  "properties": {
                    "kind": {
                      "type": "string",
                      "enum": [
                        "unique"
                      ]
                    },
                    "table": {
                      "type": "string",
                      "description": "schema-qualified, such as public.orders"
                    },
                    "columns": {
                      "type": "array",
                      "items": {
                        "type": "string"
                      }
                    }
                  },
                  "required": [
                    "kind",
                    "table",
                    "columns"
                  ],
                  "additionalProperties": false
                },
                {
                  "type": "object",
                  "properties": {
                    "kind": {
                      "type": "string",
                      "enum": [
                        "foreign_key"
                      ]
                    },
                    "table": {
                      "type": "string",
                      "description": "schema-qualified, such as public.orders"
                    },
                    "columns": {
                      "type": "array",
                      "items": {
                        "type": "string"
                      }
                    },
                    "references_table": {
                      "type": "string",
                      "description": "schema-qualified, such as public.orders"
                    },
                    "references_columns": {
                      "type": "array",
                      "items": {
                        "type": "string"
                      }
                    }
                  },
                  "required": [
                    "kind",
                    "table",
                    "columns",
                    "references_table",
                    "references_columns"
                  ],
                  "additionalProperties": false
                },
                {
                  "type": "object",
                  "properties": {
                    "kind": {
                      "type": "string",
                      "enum": [
                        "check"
                      ]
                    },
                    "table": {
                      "type": "string",
                      "description": "schema-qualified, such as public.orders"
                    },
                    "expression": {
                      "type": "string"
                    }
                  },
                  "required": [
                    "kind",
                    "table",
                    "expression"
                  ],
                  "additionalProperties": false
                }
              ]
            }
          }
        },
        "required": [
          "sql",
          "transformation",
          "assumptions"
        ],
        "additionalProperties": false
      },
      "maxItems": 5
    }
  },
  "required": [
    "rewrites"
  ],
  "additionalProperties": false
}
```
