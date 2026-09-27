SELECT u.sku, p.*
FROM unnest(ARRAY['ABX-0000100', 'QRT-0000101', 'ZMN-0000102', 'KLP-9999999']) AS u(sku)
JOIN public.products p ON p.sku = u.sku;
