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
{"payload":{"type":"rewrite_payload","query":"SELECT p.id, p.sku, p.name FROM public.products p WHERE p.category = $1 AND EXISTS (SELECT $2 FROM public.line_items li JOIN public.orders o ON o.id = li.order_id WHERE li.product_id = p.id AND o.created_at >= $3 AND li.quantity >= $4) ORDER BY p.id","placeholders":{"$1":{"type":"text","pattern":null,"elements":null,"est_rows":333,"actual_rows":333.0},"$2":{"type":"integer","pattern":null,"elements":null,"est_rows":null,"actual_rows":null},"$3":{"type":"text","pattern":null,"elements":null,"est_rows":89265,"actual_rows":89057.0},"$4":{"type":"integer","pattern":null,"elements":null,"est_rows":150080,"actual_rows":150000.0}},"plan":[{"Plan":{"Node Type":"Sort","Parallel Aware":false,"Async Capable":false,"Startup Cost":10092.24,"Total Cost":10093.07,"Plan Rows":333,"Plan Width":30,"Actual Startup Time":76.664,"Actual Total Time":76.678,"Actual Rows":167.0,"Actual Loops":1,"Disabled":false,"Sort Key":["p.id"],"Sort Method":"quicksort","Sort Space Used":32,"Sort Space Type":"Memory","Shared Hit Blocks":3162,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0,"Plans":[{"Node Type":"Hash Join","Parent Relationship":"Outer","Parallel Aware":false,"Async Capable":false,"Join Type":"Inner","Startup Cost":10030.71,"Total Cost":10078.28,"Plan Rows":333,"Plan Width":30,"Actual Startup Time":76.442,"Actual Total Time":76.637,"Actual Rows":167.0,"Actual Loops":1,"Disabled":false,"Inner Unique":true,"Hash Cond":"(p.id = li.product_id)","Shared Hit Blocks":3159,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0,"Plans":[{"Node Type":"Seq Scan","Parent Relationship":"Outer","Parallel Aware":false,"Async Capable":false,"Relation Name":"products","Alias":"p","Startup Cost":0.0,"Total Cost":43.0,"Plan Rows":333,"Plan Width":30,"Actual Startup Time":0.007,"Actual Total Time":0.166,"Actual Rows":333.0,"Actual Loops":1,"Disabled":false,"Filter":"(category = $1::text)","Rows Removed by Filter":1667,"Shared Hit Blocks":18,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0},{"Node Type":"Hash","Parent Relationship":"Inner","Parallel Aware":false,"Async Capable":false,"Startup Cost":10005.71,"Total Cost":10005.71,"Plan Rows":2000,"Plan Width":8,"Actual Startup Time":76.428,"Actual Total Time":76.433,"Actual Rows":1000.0,"Actual Loops":1,"Disabled":false,"Hash Buckets":2048,"Original Hash Buckets":2048,"Hash Batches":1,"Original Hash Batches":1,"Peak Memory Usage":56,"Shared Hit Blocks":3141,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0,"Plans":[{"Node Type":"Aggregate","Strategy":"Hashed","Partial Mode":"Simple","Parent Relationship":"Outer","Parallel Aware":false,"Async Capable":false,"Startup Cost":9985.71,"Total Cost":10005.71,"Plan Rows":2000,"Plan Width":8,"Actual Startup Time":76.232,"Actual Total Time":76.32,"Actual Rows":1000.0,"Actual Loops":1,"Disabled":false,"Group Key":["li.product_id"],"Planned Partitions":0,"HashAgg Batches":1,"Peak Memory Usage":121,"Disk Usage":0,"Shared Hit Blocks":3141,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0,"Plans":[{"Node Type":"Hash Join","Parent Relationship":"Outer","Parallel Aware":false,"Async Capable":false,"Join Type":"Inner","Startup Cost":3300.81,"Total Cost":9650.78,"Plan Rows":133969,"Plan Width":8,"Actual Startup Time":22.385,"Actual Total Time":65.042,"Actual Rows":133586.0,"Actual Loops":1,"Disabled":false,"Inner Unique":true,"Hash Cond":"(li.order_id = o.id)","Shared Hit Blocks":3141,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0,"Plans":[{"Node Type":"Seq Scan","Parent Relationship":"Outer","Parallel Aware":false,"Async Capable":false,"Relation Name":"line_items","Alias":"li","Startup Cost":0.0,"Total Cost":5956.0,"Plan Rows":150080,"Plan Width":16,"Actual Startup Time":0.007,"Actual Total Time":23.069,"Actual Rows":150000.0,"Actual Loops":1,"Disabled":false,"Filter":"(quantity >= $4)","Rows Removed by Filter":150000,"Shared Hit Blocks":2206,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0},{"Node Type":"Hash","Parent Relationship":"Inner","Parallel Aware":false,"Async Capable":false,"Startup Cost":2185.0,"Total Cost":2185.0,"Plan Rows":89265,"Plan Width":8,"Actual Startup Time":18.249,"Actual Total Time":18.249,"Actual Rows":89057.0,"Actual Loops":1,"Disabled":false,"Hash Buckets":131072,"Original Hash Buckets":131072,"Hash Batches":1,"Original Hash Batches":1,"Peak Memory Usage":4503,"Shared Hit Blocks":935,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0,"Plans":[{"Node Type":"Seq Scan","Parent Relationship":"Outer","Parallel Aware":false,"Async Capable":false,"Relation Name":"orders","Alias":"o","Startup Cost":0.0,"Total Cost":2185.0,"Plan Rows":89265,"Plan Width":8,"Actual Startup Time":0.797,"Actual Total Time":9.55,"Actual Rows":89057.0,"Actual Loops":1,"Disabled":false,"Filter":"(created_at >= $3::timestamp with time zone)","Rows Removed by Filter":10943,"Shared Hit Blocks":935,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0}]}]}]}]}]}]},"Planning":{"Shared Hit Blocks":224,"Shared Read Blocks":0,"Shared Dirtied Blocks":0,"Shared Written Blocks":0,"Local Hit Blocks":0,"Local Read Blocks":0,"Local Dirtied Blocks":0,"Local Written Blocks":0,"Temp Read Blocks":0,"Temp Written Blocks":0},"Planning Time":0.431,"Execution Time":76.886}],"schema":{"tables":[["public","line_items"],["public","orders"],["public","products"],["public","users"]],"ddl":"--\n-- PostgreSQL database dump\n--\n\n\\restrict eYcAUxZ3gCkgfWAyO7goSTjMfWE20zMNfFnalE0mtY6RlsQkbBAU8SMsqWVFmQt\n\n-- Dumped from database version 18.4 (Debian 18.4-1.pgdg13+1)\n-- Dumped by pg_dump version 18.4 (Homebrew)\n\nSET statement_timeout = 0;\nSET lock_timeout = 0;\nSET idle_in_transaction_session_timeout = 0;\nSET transaction_timeout = 0;\nSET client_encoding = 'UTF8';\nSET standard_conforming_strings = on;\nSELECT pg_catalog.set_config('search_path', '', false);\nSET check_function_bodies = false;\nSET xmloption = content;\nSET client_min_messages = warning;\nSET row_security = off;\n\nSET default_tablespace = '';\n\nSET default_table_access_method = heap;\n\n--\n-- Name: line_items; Type: TABLE; Schema: public; Owner: -\n--\n\nCREATE TABLE public.line_items (\n    id bigint NOT NULL,\n    order_id bigint NOT NULL,\n    product_id bigint NOT NULL,\n    quantity integer NOT NULL,\n    unit_price_cents integer NOT NULL\n);\n\n\n--\n-- Name: line_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -\n--\n\nALTER TABLE public.line_items ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (\n    SEQUENCE NAME public.line_items_id_seq\n    START WITH 1\n    INCREMENT BY 1\n    NO MINVALUE\n    NO MAXVALUE\n    CACHE 1\n);\n\n\n--\n-- Name: orders; Type: TABLE; Schema: public; Owner: -\n--\n\nCREATE TABLE public.orders (\n    id bigint NOT NULL,\n    user_id bigint NOT NULL,\n    status text NOT NULL,\n    total_cents integer NOT NULL,\n    created_at timestamp with time zone NOT NULL,\n    updated_at timestamp with time zone NOT NULL\n);\n\n\n--\n-- Name: orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -\n--\n\nALTER TABLE public.orders ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (\n    SEQUENCE NAME public.orders_id_seq\n    START WITH 1\n    INCREMENT BY 1\n    NO MINVALUE\n    NO MAXVALUE\n    CACHE 1\n);\n\n\n--\n-- Name: products; Type: TABLE; Schema: public; Owner: -\n--\n\nCREATE TABLE public.products (\n    id bigint NOT NULL,\n    sku text NOT NULL,\n    name text NOT NULL,\n    category text NOT NULL,\n    price_cents integer NOT NULL\n);\n\n\n--\n-- Name: products_id_seq; Type: SEQUENCE; Schema: public; Owner: -\n--\n\nALTER TABLE public.products ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (\n    SEQUENCE NAME public.products_id_seq\n    START WITH 1\n    INCREMENT BY 1\n    NO MINVALUE\n    NO MAXVALUE\n    CACHE 1\n);\n\n\n--\n-- Name: users; Type: TABLE; Schema: public; Owner: -\n--\n\nCREATE TABLE public.users (\n    id bigint NOT NULL,\n    email text NOT NULL,\n    name text,\n    country text NOT NULL,\n    status text NOT NULL,\n    created_at timestamp with time zone NOT NULL\n);\n\n\n--\n-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -\n--\n\nALTER TABLE public.users ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (\n    SEQUENCE NAME public.users_id_seq\n    START WITH 1\n    INCREMENT BY 1\n    NO MINVALUE\n    NO MAXVALUE\n    CACHE 1\n);\n\n\n--\n-- Name: line_items line_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.line_items\n    ADD CONSTRAINT line_items_pkey PRIMARY KEY (id);\n\n\n--\n-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.orders\n    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);\n\n\n--\n-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.products\n    ADD CONSTRAINT products_pkey PRIMARY KEY (id);\n\n\n--\n-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.users\n    ADD CONSTRAINT users_pkey PRIMARY KEY (id);\n\n\n--\n-- Name: line_items_order_id_idx; Type: INDEX; Schema: public; Owner: -\n--\n\nCREATE INDEX line_items_order_id_idx ON public.line_items USING btree (order_id);\n\n\n--\n-- Name: orders_user_id_idx; Type: INDEX; Schema: public; Owner: -\n--\n\nCREATE INDEX orders_user_id_idx ON public.orders USING btree (user_id);\n\n\n--\n-- Name: products_sku_key; Type: INDEX; Schema: public; Owner: -\n--\n\nCREATE UNIQUE INDEX products_sku_key ON public.products USING btree (sku);\n\n\n--\n-- Name: users_email_key; Type: INDEX; Schema: public; Owner: -\n--\n\nCREATE UNIQUE INDEX users_email_key ON public.users USING btree (email);\n\n\n--\n-- Name: line_items line_items_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.line_items\n    ADD CONSTRAINT line_items_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id);\n\n\n--\n-- Name: line_items line_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.line_items\n    ADD CONSTRAINT line_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id);\n\n\n--\n-- Name: orders orders_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -\n--\n\nALTER TABLE ONLY public.orders\n    ADD CONSTRAINT orders_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);\n\n\n--\n-- PostgreSQL database dump complete\n--\n\n\\unrestrict eYcAUxZ3gCkgfWAyO7goSTjMfWE20zMNfFnalE0mtY6RlsQkbBAU8SMsqWVFmQt\n\n"},"stats":{"tables":[{"schema":"public","name":"products","columns":[{"name":"id","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null},{"name":"sku","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null},{"name":"name","n_distinct":-1.0,"null_frac":0.0,"correlation":-0.38968256,"most_common_freqs":null,"most_common_vals":null},{"name":"category","n_distinct":6.0,"null_frac":0.0,"correlation":0.16591671,"most_common_freqs":[0.167,0.167,0.1665,0.1665,0.1665,0.1665],"most_common_vals":["games","garden","books","kitchen","tools","toys"]},{"name":"price_cents","n_distinct":-1.0,"null_frac":0.0,"correlation":0.11224419,"most_common_freqs":null,"most_common_vals":null}],"indexes":[{"name":"products_pkey","definition":"CREATE UNIQUE INDEX products_pkey ON public.products USING btree (id)","columns":[]},{"name":"products_sku_key","definition":"CREATE UNIQUE INDEX products_sku_key ON public.products USING btree (sku)","columns":[]}],"extended_statistics":[]},{"schema":"public","name":"line_items","columns":[{"name":"id","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null},{"name":"order_id","n_distinct":-0.33455333,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null},{"name":"product_id","n_distinct":2000.0,"null_frac":0.0,"correlation":-0.0012177415,"most_common_freqs":[0.0009,0.0009,0.00086666667,0.00086666667,0.00083333335,0.00083333335,0.00083333335,0.00083333335,0.00083333335,0.00083333335],"most_common_vals":null},{"name":"quantity","n_distinct":4.0,"null_frac":0.0,"correlation":0.24915324,"most_common_freqs":[0.25276667,0.25146666,0.24826667,0.2475],"most_common_vals":["4","1","2","3"]},{"name":"unit_price_cents","n_distinct":19914.0,"null_frac":0.0,"correlation":-0.0051862565,"most_common_freqs":[0.00026666667],"most_common_vals":null}],"indexes":[{"name":"line_items_order_id_idx","definition":"CREATE INDEX line_items_order_id_idx ON public.line_items USING btree (order_id)","columns":[]},{"name":"line_items_pkey","definition":"CREATE UNIQUE INDEX line_items_pkey ON public.line_items USING btree (id)","columns":[]}],"extended_statistics":[]},{"schema":"public","name":"orders","columns":[{"name":"id","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null},{"name":"user_id","n_distinct":-0.19974,"null_frac":0.0,"correlation":-0.0017311382,"most_common_freqs":null,"most_common_vals":null},{"name":"status","n_distinct":5.0,"null_frac":0.0,"correlation":0.25989088,"most_common_freqs":[0.4268,0.14396666,0.14336666,0.14306666,0.1428],"most_common_vals":["delivered","refunded","shipped","pending","cancelled"]},{"name":"total_cents","n_distinct":-0.50026,"null_frac":0.0,"correlation":0.009072244,"most_common_freqs":null,"most_common_vals":null},{"name":"created_at","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null},{"name":"updated_at","n_distinct":-1.0,"null_frac":0.0,"correlation":1.0,"most_common_freqs":null,"most_common_vals":null}],"indexes":[{"name":"orders_pkey","definition":"CREATE UNIQUE INDEX orders_pkey ON public.orders USING btree (id)","columns":[]},{"name":"orders_user_id_idx","definition":"CREATE INDEX orders_user_id_idx ON public.orders USING btree (user_id)","columns":[]}],"extended_statistics":[]}]}},"rewrites":["SELECT p.id, p.sku, p.name FROM public.products p WHERE p.category = $1 AND p.id IN (SELECT li.product_id FROM public.line_items li JOIN public.orders o ON o.id = li.order_id WHERE o.created_at >= $2 AND li.quantity >= $3) ORDER BY p.id;"]}
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
