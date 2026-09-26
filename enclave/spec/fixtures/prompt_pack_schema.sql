-- The prompt pack's schema (script/prompt_pack): a small shop, the kind an
-- ORM app has. users place orders, orders hold line_items of products.

CREATE TABLE public.users (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email text NOT NULL,
  name text,
  country text NOT NULL,
  status text NOT NULL,
  created_at timestamptz NOT NULL
);

CREATE UNIQUE INDEX users_email_key ON public.users (email);

CREATE TABLE public.products (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sku text NOT NULL,
  name text NOT NULL,
  category text NOT NULL,
  price_cents integer NOT NULL
);

CREATE UNIQUE INDEX products_sku_key ON public.products (sku);

CREATE TABLE public.orders (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id bigint NOT NULL REFERENCES public.users (id),
  status text NOT NULL,
  total_cents integer NOT NULL,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE INDEX orders_user_id_idx ON public.orders (user_id);

CREATE TABLE public.line_items (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id bigint NOT NULL REFERENCES public.orders (id),
  product_id bigint NOT NULL REFERENCES public.products (id),
  quantity integer NOT NULL,
  unit_price_cents integer NOT NULL
);

CREATE INDEX line_items_order_id_idx ON public.line_items (order_id);
