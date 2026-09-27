# System

An operator has written rewrites of one slow PostgreSQL query. You have no database connection. You get the payload for the original query, which holds only shapes: the query with $n placeholders for its literals, each placeholder's shape, the plan, the schema, and per-column statistics. You also get the operator's rewrites, which use the same placeholders.

For each rewrite, in order, compare it with the original and infer the transformation it applies, and every assumption it seems to rely on to return the same rows. Only these kinds of assumption are allowed:
- not_null: a column is NOT NULL.
- unique: a set of columns is unique.
- foreign_key: columns reference another table's columns.
- check: a CHECK constraint with exactly this expression.
Tables are always schema-qualified, such as public.orders.

Answer with JSON, one entry per rewrite in the same order: {"rewrites": [{"transformation": "...", "assumptions": [...]}]}.

# User

The original and the rewrites:

```json
{"payload":{"type":"rewrite_payload","query":"SELECT o.id, o.total_cents, o.created_at, u.email FROM public.orders o JOIN public.users u ON u.id = o.user_id WHERE u.country = $1 AND o.created_at >= $2 AND o.created_at < $3 ORDER BY o.created_at DESC LIMIT $4","placeholders":{"$1":{"type":"text","pattern":null,"elements":null,"est_rows":7500,"actual_rows":7500.0},"$2":{"type":"timestamp with time zone","pattern":null,"elements":null,"est_rows":21112,"actual_rows":21168.0},"$3":{"type":"timestamp with time zone","pattern":null,"elements":null,"est_rows":21112,"actual_rows":21168.0},"$4":{"type":"bigint","pattern":null,"elements":null,"est_rows":null,"actual_rows":null}},"plan":[{"Plan":{"Node Type":"Limit","Parallel Aware":false,"Async Capable":false,"Startup Cost":3324.18,"Total Cost":3324.3,"Plan Rows":50,"Plan Width":41,"Actual Startup Time":13.92,"Actual Total Time":13.928,"Actual Rows":50.0,"Actual Loops":1,"Disabled":false,"Shared Hit Blocks":1165,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0,"Plans":[{"Node Type":"Sort","Parent Relationship":"Outer","Parallel Aware":false,"Async Capable":false,"Startup Cost":3324.18,"Total Cost":3343.97,"Plan Rows":7917,"Plan Width":41,"Actual Startup Time":13.919,"Actual Total Time":13.923,"Actual Rows":50.0,"Actual Loops":1,"Disabled":false,"Sort Key":["o.created_at DESC"],"Sort Method":"top-N heapsort","Sort Space Used":32,"Sort Space Type":"Memory","Shared Hit Blocks":1165,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0,"Plans":[{"Node Type":"Hash Join","Parent Relationship":"Outer","Parallel Aware":false,"Async Capable":false,"Join Type":"Inner","Startup Cost":570.75,"Total Cost":3061.18,"Plan Rows":7917,"Plan Width":41,"Actual Startup Time":4.484,"Actual Total Time":12.76,"Actual Rows":7938.0,"Actual Loops":1,"Disabled":false,"Inner Unique":true,"Hash Cond":"(o.user_id = u.id)","Shared Hit Blocks":1162,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0,"Plans":[{"Node Type":"Seq Scan","Parent Relationship":"Outer","Parallel Aware":false,"Async Capable":false,"Relation Name":"orders","Alias":"o","Startup Cost":0.0,"Total Cost":2435.0,"Plan Rows":21112,"Plan Width":28,"Actual Startup Time":1.545,"Actual Total Time":7.882,"Actual Rows":21168.0,"Actual Loops":1,"Disabled":false,"Filter":"((created_at >= $2::timestamp with time zone) AND (created_at < $3::timestamp with time zone))","Rows Removed by Filter":78832,"Shared Hit Blocks":935,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0},{"Node Type":"Hash","Parent Relationship":"Inner","Parallel Aware":false,"Async Capable":false,"Startup Cost":477.0,"Total Cost":477.0,"Plan Rows":7500,"Plan Width":29,"Actual Startup Time":2.924,"Actual Total Time":2.924,"Actual Rows":7500.0,"Actual Loops":1,"Disabled":false,"Hash Buckets":8192,"Original Hash Buckets":8192,"Hash Batches":1,"Original Hash Batches":1,"Peak Memory Usage":533,"Shared Hit Blocks":227,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0,"Plans":[{"Node Type":"Seq Scan","Parent Relationship":"Outer","Parallel Aware":false,"Async Capable":false,"Relation Name":"users","Alias":"u","Startup Cost":0.0,"Total Cost":477.0,"Plan Rows":7500,"Plan Width":29,"Actual Startup Time":0.006,"Actual Total Time":2.046,"Actual Rows":7500.0,"Actual Loops":1,"Disabled":false,"Filter":"(country = $1::text)","Rows Removed by Filter":12500,"Shared Hit Blocks":227,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0}]}]}]}]},"Planning":{"Shared Hit Blocks":260,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0},"Planning Time":0.429,"Execution Time":13.954}],"schema":{"tables":[["public","orders"],["public","users"]],"ddl":"--\n-- PostgreSQL database dump\n--\n\n\n-- Dumped from database version 18.4 (Debian 18.4-1.pgdg13+1)\n-- Dumped by pg_dump version 18.4 (Homebrew)\n\nSET statement_timeout = 0;\nSET lock_timeout = 0;\nSET idle_in_transaction_session_timeout = 0;\nSET transaction_timeout = 0;\nSET client_encoding = 'UTF8';\nSET standard_conforming_strings = on;\nSELECT pg_catalog.set_config('search_path', '', false);\nSET check_function_bodies = false;\nSET xmloption = content;\nSET client_min_messages = warning;\nSET row_security = off;\n\nSET default_tablespace = '';\n\nSET default_table_access_method = heap;\n\n--\n-- Name: orders; Type: TABLE; Schema: public; Owner: -\n--\n\nCREATE TABLE public.orders (\n    id bigint NOT NULL,\n    user_id bigint NOT NULL,\n    status text NOT NULL,\n    total_cents integer NOT NULL,\n    created_at timestamp with time zone NOT NULL,\n    updated_at timestamp with time zone NOT NULL\n);\n\n\n--\n-- Name: orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -\n--\n\nALTER TABLE public.orders ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (\n    SEQUENCE NAME public.orders_id_seq\n    START WITH 1\n    INCREMENT BY 1\n    NO MINVALUE\n    NO MAXVALUE\n    CACHE 1\n);\n\n\n--\n-- Name: users; Type: TABLE; Schema: public; Owner: -\n--\n\nCREATE TABLE public.users (\n    id bigint NOT NULL,\n    email text NOT NULL,\n    name text,\n    country text NOT NULL,\n    status text NOT NULL,\n    created_at timestamp with time zone NOT NULL\n);\n\n\n--\n-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -\n--\n\nALTER TABLE public.users ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (\n    SEQUENCE NAME public.users_id_seq\n    START WITH 1\n    INCREMENT BY 1\n    NO MINVALUE\n    NO MAXVALUE\n    CACHE 1\n);\n\n\n--\n-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.orders\n    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);\n\n\n--\n-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.users\n    ADD CONSTRAINT users_pkey PRIMARY KEY (id);\n\n\n--\n-- Name: orders_user_id_idx; Type: INDEX; Schema: public; Owner: -\n--\n\nCREATE INDEX orders_user_id_idx ON public.orders USING btree (user_id);\n\n\n--\n-- Name: users_email_key; Type: INDEX; Schema: public; Owner: -\n--\n\nCREATE UNIQUE INDEX users_email_key ON public.users USING btree (email);\n\n\n--\n-- Name: orders orders_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.orders\n    ADD CONSTRAINT orders_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);\n\n\n--\n-- PostgreSQL database dump complete\n--\n\n\n"},"stats":{"tables":[{"schema":"public","name":"orders","columns":[{"name":"id","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null},{"name":"user_id","n_distinct":-0.20157,"null_frac":0.0,"correlation":-0.0053011747,"most_common_freqs":null,"most_common_vals":null},{"name":"status","n_distinct":5.0,"null_frac":0.0,"correlation":0.26533556,"most_common_freqs":[0.4322,0.1436,0.14186667,0.14143333,0.1409],"most_common_vals":["delivered","shipped","cancelled","refunded","pending"]},{"name":"total_cents","n_distinct":-0.49642,"null_frac":0.0,"correlation":0.008700528,"most_common_freqs":null,"most_common_vals":null},{"name":"created_at","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null},{"name":"updated_at","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null}],"indexes":[{"name":"orders_pkey","definition":"CREATE UNIQUE INDEX orders_pkey ON public.orders USING btree (id)","columns":[]},{"name":"orders_user_id_idx","definition":"CREATE INDEX orders_user_id_idx ON public.orders USING btree (user_id)","columns":[]}],"extended_statistics":[]},{"schema":"public","name":"users","columns":[{"name":"id","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null},{"name":"email","n_distinct":-1.0,"null_frac":0.0,"correlation":-0.39445555,"most_common_freqs":null,"most_common_vals":null},{"name":"name","n_distinct":-1.0,"null_frac":0.0,"correlation":-0.39336452,"most_common_freqs":null,"most_common_vals":null},{"name":"country","n_distinct":6.0,"null_frac":0.0,"correlation":0.21857187,"most_common_freqs":[0.375,0.125,0.125,0.125,0.125,0.125],"most_common_vals":["US","BR","CA","DE","FR","GB"]},{"name":"status","n_distinct":3.0,"null_frac":0.0,"correlation":0.50004166,"most_common_freqs":[0.6667,0.16665,0.16665],"most_common_vals":["active","closed","suspended"]},{"name":"created_at","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null}],"indexes":[{"name":"users_email_key","definition":"CREATE UNIQUE INDEX users_email_key ON public.users USING btree (email)","columns":[]},{"name":"users_pkey","definition":"CREATE UNIQUE INDEX users_pkey ON public.users USING btree (id)","columns":[]}],"extended_statistics":[]}]}},"rewrites":["SELECT o.id, o.total_cents, o.created_at, u.email FROM public.orders o JOIN public.users u ON u.id = o.user_id AND u.country = $1 WHERE o.created_at >= $2 AND o.created_at < $3 ORDER BY o.created_at DESC LIMIT $4;"]}
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
          "transformation",
          "assumptions"
        ],
        "additionalProperties": false
      }
    }
  },
  "required": [
    "rewrites"
  ],
  "additionalProperties": false
}
```
