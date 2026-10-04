# System

An operator has written rewrites of one slow PostgreSQL query. You have no database connection. You get the payload for the original query, which holds only shapes: the query with $n placeholders for its literals, each placeholder's shape, the plan, the schema, and per-column statistics. You also get the operator's rewrites, which use the same placeholders.

For each rewrite, in order, compare it with the original and infer the transformation it applies, and every assumption it seems to rely on to return the same rows. Only these kinds of assumption are allowed:
- not_null: a column is NOT NULL.
- unique: a set of columns is unique.
- foreign_key: columns reference another table's columns.
- check: a CHECK constraint with exactly this expression.
Tables are always schema-qualified, such as public.orders.

Answer with JSON, one entry per rewrite in the same order: {"rewrites": [{"transformation": "...", "assumptions": [...]}]}.


Reply with only the JSON object, with no code fences, commentary, or trailing text.

# User

The original and the rewrites:

```json
{"payload":{"type":"rewrite_payload","query":"SELECT o.id, o.created_at, o.total_cents FROM public.orders o WHERE (o.created_at, o.id) < ($1, $2) ORDER BY o.created_at DESC, o.id DESC LIMIT $3","placeholders":{"$1":{"type":"timestamp with time zone","pattern":null,"elements":null,"est_rows":47016,"actual_rows":46821.0},"$2":{"type":"integer","pattern":null,"elements":null,"est_rows":47016,"actual_rows":46821.0},"$3":{"type":"integer","pattern":null,"elements":null,"est_rows":null,"actual_rows":null}},"plan":[{"Plan":{"Node Type":"Limit","Parallel Aware":false,"Async Capable":false,"Startup Cost":3761.76,"Total Cost":3761.82,"Plan Rows":25,"Plan Width":20,"Actual Startup Time":14.396,"Actual Total Time":14.4,"Actual Rows":25.0,"Actual Loops":1,"Disabled":false,"Shared Hit Blocks":941,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0,"Plans":[{"Node Type":"Sort","Parent Relationship":"Outer","Parallel Aware":false,"Async Capable":false,"Startup Cost":3761.76,"Total Cost":3879.3,"Plan Rows":47016,"Plan Width":20,"Actual Startup Time":14.395,"Actual Total Time":14.396,"Actual Rows":25.0,"Actual Loops":1,"Disabled":false,"Sort Key":["created_at DESC","id DESC"],"Sort Method":"top-N heapsort","Sort Space Used":28,"Sort Space Type":"Memory","Shared Hit Blocks":941,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0,"Plans":[{"Node Type":"Seq Scan","Parent Relationship":"Outer","Parallel Aware":false,"Async Capable":false,"Relation Name":"orders","Alias":"o","Startup Cost":0.0,"Total Cost":2435.0,"Plan Rows":47016,"Plan Width":20,"Actual Startup Time":0.007,"Actual Total Time":8.95,"Actual Rows":46821.0,"Actual Loops":1,"Disabled":false,"Filter":"(ROW(created_at, id) < ROW($1::timestamp with time zone, $2))","Rows Removed by Filter":53179,"Shared Hit Blocks":935,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0}]}]},"Planning":{"Shared Hit Blocks":95,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0},"Planning Time":0.165,"Execution Time":14.421}],"schema":{"tables":[["public","orders"],["public","users"]],"ddl":"--\n-- PostgreSQL database dump\n--\n\n\n-- Dumped from database version 18.4 (Debian 18.4-1.pgdg13+1)\n-- Dumped by pg_dump version 18.4 (Homebrew)\n\nSET statement_timeout = 0;\nSET lock_timeout = 0;\nSET idle_in_transaction_session_timeout = 0;\nSET transaction_timeout = 0;\nSET client_encoding = 'UTF8';\nSET standard_conforming_strings = on;\nSELECT pg_catalog.set_config('search_path', '', false);\nSET check_function_bodies = false;\nSET xmloption = content;\nSET client_min_messages = warning;\nSET row_security = off;\n\nSET default_tablespace = '';\n\nSET default_table_access_method = heap;\n\n--\n-- Name: orders; Type: TABLE; Schema: public; Owner: -\n--\n\nCREATE TABLE public.orders (\n    id bigint NOT NULL,\n    user_id bigint NOT NULL,\n    status text NOT NULL,\n    total_cents integer NOT NULL,\n    created_at timestamp with time zone NOT NULL,\n    updated_at timestamp with time zone NOT NULL\n);\n\n\n--\n-- Name: orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -\n--\n\nALTER TABLE public.orders ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (\n    SEQUENCE NAME public.orders_id_seq\n    START WITH 1\n    INCREMENT BY 1\n    NO MINVALUE\n    NO MAXVALUE\n    CACHE 1\n);\n\n\n--\n-- Name: users; Type: TABLE; Schema: public; Owner: -\n--\n\nCREATE TABLE public.users (\n    id bigint NOT NULL,\n    email text NOT NULL,\n    name text,\n    country text NOT NULL,\n    status text NOT NULL,\n    created_at timestamp with time zone NOT NULL\n);\n\n\n--\n-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -\n--\n\nALTER TABLE public.users ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (\n    SEQUENCE NAME public.users_id_seq\n    START WITH 1\n    INCREMENT BY 1\n    NO MINVALUE\n    NO MAXVALUE\n    CACHE 1\n);\n\n\n--\n-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.orders\n    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);\n\n\n--\n-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.users\n    ADD CONSTRAINT users_pkey PRIMARY KEY (id);\n\n\n--\n-- Name: orders_user_id_idx; Type: INDEX; Schema: public; Owner: -\n--\n\nCREATE INDEX orders_user_id_idx ON public.orders USING btree (user_id);\n\n\n--\n-- Name: users_email_key; Type: INDEX; Schema: public; Owner: -\n--\n\nCREATE UNIQUE INDEX users_email_key ON public.users USING btree (email);\n\n\n--\n-- Name: orders orders_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.orders\n    ADD CONSTRAINT orders_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);\n\n\n--\n-- PostgreSQL database dump complete\n--\n\n\n"},"stats":{"tables":[{"schema":"public","name":"orders","columns":[{"name":"id","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null},{"name":"user_id","n_distinct":-0.20047,"null_frac":0.0,"correlation":-0.0000017856298,"most_common_freqs":null,"most_common_vals":null},{"name":"status","n_distinct":5.0,"null_frac":0.0,"correlation":0.25698105,"most_common_freqs":[0.42373332,0.14593333,0.145,0.14283334,0.1425],"most_common_vals":["delivered","pending","cancelled","refunded","shipped"]},{"name":"total_cents","n_distinct":-0.49922,"null_frac":0.0,"correlation":0.0075464915,"most_common_freqs":null,"most_common_vals":null},{"name":"created_at","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null},{"name":"updated_at","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null}],"indexes":[{"name":"orders_pkey","definition":"CREATE UNIQUE INDEX orders_pkey ON public.orders USING btree (id)","columns":[]},{"name":"orders_user_id_idx","definition":"CREATE INDEX orders_user_id_idx ON public.orders USING btree (user_id)","columns":[]}],"extended_statistics":[]}]}},"rewrites":["SELECT o.id, o.created_at, o.total_cents FROM public.orders o WHERE o.created_at <= $1 AND (o.created_at < $1 OR o.id < $2) ORDER BY o.created_at DESC, o.id DESC LIMIT $3;"]}
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
