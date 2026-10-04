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


Reply with only the JSON object, with no code fences, commentary, or trailing text.

# User

The payload:

```json
{"type":"rewrite_payload","query":"SELECT o.id, o.total_cents, o.created_at, u.email FROM public.orders o JOIN public.users u ON u.id = o.user_id WHERE u.country = $1 AND o.created_at >= $2 AND o.created_at < $3 ORDER BY o.created_at DESC LIMIT $4","placeholders":{"$1":{"type":"text","pattern":null,"elements":null,"est_rows":7500,"actual_rows":7500.0},"$2":{"type":"timestamp with time zone","pattern":null,"elements":null,"est_rows":21088,"actual_rows":21168.0},"$3":{"type":"timestamp with time zone","pattern":null,"elements":null,"est_rows":21088,"actual_rows":21168.0},"$4":{"type":"integer","pattern":null,"elements":null,"est_rows":null,"actual_rows":null}},"plan":[{"Plan":{"Node Type":"Limit","Parallel Aware":false,"Async Capable":false,"Startup Cost":3323.82,"Total Cost":3323.94,"Plan Rows":50,"Plan Width":41,"Actual Startup Time":12.875,"Actual Total Time":12.883,"Actual Rows":50.0,"Actual Loops":1,"Disabled":false,"Shared Hit Blocks":1165,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0,"Plans":[{"Node Type":"Sort","Parent Relationship":"Outer","Parallel Aware":false,"Async Capable":false,"Startup Cost":3323.82,"Total Cost":3343.59,"Plan Rows":7908,"Plan Width":41,"Actual Startup Time":12.874,"Actual Total Time":12.878,"Actual Rows":50.0,"Actual Loops":1,"Disabled":false,"Sort Key":["o.created_at DESC"],"Sort Method":"top-N heapsort","Sort Space Used":32,"Sort Space Type":"Memory","Shared Hit Blocks":1165,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0,"Plans":[{"Node Type":"Hash Join","Parent Relationship":"Outer","Parallel Aware":false,"Async Capable":false,"Join Type":"Inner","Startup Cost":570.75,"Total Cost":3061.12,"Plan Rows":7908,"Plan Width":41,"Actual Startup Time":4.138,"Actual Total Time":11.725,"Actual Rows":7938.0,"Actual Loops":1,"Disabled":false,"Inner Unique":true,"Hash Cond":"(o.user_id = u.id)","Shared Hit Blocks":1162,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0,"Plans":[{"Node Type":"Seq Scan","Parent Relationship":"Outer","Parallel Aware":false,"Async Capable":false,"Relation Name":"orders","Alias":"o","Startup Cost":0.0,"Total Cost":2435.0,"Plan Rows":21088,"Plan Width":28,"Actual Startup Time":1.405,"Actual Total Time":7.128,"Actual Rows":21168.0,"Actual Loops":1,"Disabled":false,"Filter":"((created_at >= $2::timestamp with time zone) AND (created_at < $3::timestamp with time zone))","Rows Removed by Filter":78832,"Shared Hit Blocks":935,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0},{"Node Type":"Hash","Parent Relationship":"Inner","Parallel Aware":false,"Async Capable":false,"Startup Cost":477.0,"Total Cost":477.0,"Plan Rows":7500,"Plan Width":29,"Actual Startup Time":2.717,"Actual Total Time":2.718,"Actual Rows":7500.0,"Actual Loops":1,"Disabled":false,"Hash Buckets":8192,"Original Hash Buckets":8192,"Hash Batches":1,"Original Hash Batches":1,"Peak Memory Usage":533,"Shared Hit Blocks":227,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0,"Plans":[{"Node Type":"Seq Scan","Parent Relationship":"Outer","Parallel Aware":false,"Async Capable":false,"Relation Name":"users","Alias":"u","Startup Cost":0.0,"Total Cost":477.0,"Plan Rows":7500,"Plan Width":29,"Actual Startup Time":0.005,"Actual Total Time":1.858,"Actual Rows":7500.0,"Actual Loops":1,"Disabled":false,"Filter":"(country = $1::text)","Rows Removed by Filter":12500,"Shared Hit Blocks":227,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0}]}]}]}]},"Planning":{"Shared Hit Blocks":260,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0},"Planning Time":0.393,"Execution Time":12.907}],"schema":{"tables":[["public","orders"],["public","users"]],"ddl":"--\n-- PostgreSQL database dump\n--\n\n\n-- Dumped from database version 18.4 (Debian 18.4-1.pgdg13+1)\n-- Dumped by pg_dump version 18.4 (Homebrew)\n\nSET statement_timeout = 0;\nSET lock_timeout = 0;\nSET idle_in_transaction_session_timeout = 0;\nSET transaction_timeout = 0;\nSET client_encoding = 'UTF8';\nSET standard_conforming_strings = on;\nSELECT pg_catalog.set_config('search_path', '', false);\nSET check_function_bodies = false;\nSET xmloption = content;\nSET client_min_messages = warning;\nSET row_security = off;\n\nSET default_tablespace = '';\n\nSET default_table_access_method = heap;\n\n--\n-- Name: orders; Type: TABLE; Schema: public; Owner: -\n--\n\nCREATE TABLE public.orders (\n    id bigint NOT NULL,\n    user_id bigint NOT NULL,\n    status text NOT NULL,\n    total_cents integer NOT NULL,\n    created_at timestamp with time zone NOT NULL,\n    updated_at timestamp with time zone NOT NULL\n);\n\n\n--\n-- Name: orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -\n--\n\nALTER TABLE public.orders ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (\n    SEQUENCE NAME public.orders_id_seq\n    START WITH 1\n    INCREMENT BY 1\n    NO MINVALUE\n    NO MAXVALUE\n    CACHE 1\n);\n\n\n--\n-- Name: users; Type: TABLE; Schema: public; Owner: -\n--\n\nCREATE TABLE public.users (\n    id bigint NOT NULL,\n    email text NOT NULL,\n    name text,\n    country text NOT NULL,\n    status text NOT NULL,\n    created_at timestamp with time zone NOT NULL\n);\n\n\n--\n-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -\n--\n\nALTER TABLE public.users ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (\n    SEQUENCE NAME public.users_id_seq\n    START WITH 1\n    INCREMENT BY 1\n    NO MINVALUE\n    NO MAXVALUE\n    CACHE 1\n);\n\n\n--\n-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.orders\n    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);\n\n\n--\n-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.users\n    ADD CONSTRAINT users_pkey PRIMARY KEY (id);\n\n\n--\n-- Name: orders_user_id_idx; Type: INDEX; Schema: public; Owner: -\n--\n\nCREATE INDEX orders_user_id_idx ON public.orders USING btree (user_id);\n\n\n--\n-- Name: users_email_key; Type: INDEX; Schema: public; Owner: -\n--\n\nCREATE UNIQUE INDEX users_email_key ON public.users USING btree (email);\n\n\n--\n-- Name: orders orders_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.orders\n    ADD CONSTRAINT orders_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);\n\n\n--\n-- PostgreSQL database dump complete\n--\n\n\n"},"stats":{"tables":[{"schema":"public","name":"orders","columns":[{"name":"id","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null},{"name":"user_id","n_distinct":-0.19952,"null_frac":0.0,"correlation":0.002387413,"most_common_freqs":null,"most_common_vals":null},{"name":"status","n_distinct":5.0,"null_frac":0.0,"correlation":0.26983538,"most_common_freqs":[0.43166667,0.1433,0.14233333,0.14153333,0.14116667],"most_common_vals":["delivered","shipped","pending","cancelled","refunded"]},{"name":"total_cents","n_distinct":-0.49961,"null_frac":0.0,"correlation":0.008018289,"most_common_freqs":null,"most_common_vals":null},{"name":"created_at","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null},{"name":"updated_at","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null}],"indexes":[{"name":"orders_pkey","definition":"CREATE UNIQUE INDEX orders_pkey ON public.orders USING btree (id)","columns":[]},{"name":"orders_user_id_idx","definition":"CREATE INDEX orders_user_id_idx ON public.orders USING btree (user_id)","columns":[]}],"extended_statistics":[]},{"schema":"public","name":"users","columns":[{"name":"id","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null},{"name":"email","n_distinct":-1.0,"null_frac":0.0,"correlation":-0.39445555,"most_common_freqs":null,"most_common_vals":null},{"name":"name","n_distinct":-1.0,"null_frac":0.0,"correlation":-0.39336452,"most_common_freqs":null,"most_common_vals":null},{"name":"country","n_distinct":6.0,"null_frac":0.0,"correlation":0.21857187,"most_common_freqs":[0.375,0.125,0.125,0.125,0.125,0.125],"most_common_vals":["US","BR","CA","DE","FR","GB"]},{"name":"status","n_distinct":3.0,"null_frac":0.0,"correlation":0.50004166,"most_common_freqs":[0.6667,0.16665,0.16665],"most_common_vals":["active","closed","suspended"]},{"name":"created_at","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null}],"indexes":[{"name":"users_email_key","definition":"CREATE UNIQUE INDEX users_email_key ON public.users USING btree (email)","columns":[]},{"name":"users_pkey","definition":"CREATE UNIQUE INDEX users_pkey ON public.users USING btree (id)","columns":[]}],"extended_statistics":[]}]}}
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
