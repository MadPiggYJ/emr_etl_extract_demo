-- =============================================================
-- Module 1: Data Generation — 1000 realistic rows
-- Uses generate_series + randomised expressions
-- No external extensions required (pure SQL)
-- =============================================================

INSERT INTO ecommerce.orders (
    customer_name,
    shipping_address,
    order_amount,
    customer_rating,
    is_repeat_customer,
    order_date,
    created_at,
    delivery_window,
    product_metadata,
    promo_codes,
    order_status,
    delivery_lat,
    delivery_lon
)
SELECT
    -- customer_name: pick from a pool of 200 realistic names
    (ARRAY[
        'Alice Wang','Bob Smith','Carol Zhang','David Lee','Emma Chen',
        'Frank Liu','Grace Kim','Henry Park','Isabella Tan','James Wu',
        'Karen Ho','Liam Ng','Mia Zhou','Noah Lin','Olivia Xu',
        'Peter Yang','Quinn Ma','Rachel Sun','Samuel He','Tina Gao',
        'Uma Luo','Victor Peng','Wendy Bai','Xander Fu','Yuna Jiang',
        'Zoe Huang','Aaron Shen','Bella Cao','Chris Zhu','Diana Fang',
        'Ethan Qi','Fiona Deng','George Han','Hannah Jin','Ivan Xiao',
        'Julia Yin','Kevin Liang','Laura Cui','Michael Du','Nancy Gu'
    ])[1 + (random() * 39)::int] AS customer_name,

    -- shipping_address: unit + street + city + postcode
    format(
        '%s/%s %s %s, %s %s',
        (random() * 20 + 1)::int,
        (random() * 200 + 1)::int,
        (ARRAY['Queen St','King Ave','Market Rd','Park Blvd','George St',
               'Collins St','Pitt St','Elizabeth Ave','Spencer Rd','Hunter St'
        ])[1 + (random() * 9)::int],
        (ARRAY['Sydney','Melbourne','Brisbane','Perth','Adelaide',
               'Canberra','Hobart','Darwin','Gold Coast','Newcastle'
        ])[1 + (random() * 9)::int],
        (ARRAY['NSW','VIC','QLD','WA','SA','ACT','TAS','NT'])[1 + (random() * 7)::int],
        (1000 + (random() * 8999)::int)::text
    ) AS shipping_address,

    -- order_amount: skewed toward lower values, occasional large orders
    ROUND((
        CASE
            WHEN random() < 0.7 THEN random() * 300        -- 70% small orders
            WHEN random() < 0.9 THEN 300 + random() * 700  -- 20% medium
            ELSE 1000 + random() * 4000                     -- 10% large
        END
    )::numeric, 2) AS order_amount,

    -- customer_rating: NULL ~10% of the time (not all customers rate)
    CASE WHEN random() < 0.9
         THEN (1 + (random() * 4)::int)::smallint
         ELSE NULL
    END AS customer_rating,

    -- is_repeat_customer: 35% are repeat buyers
    (random() < 0.35) AS is_repeat_customer,

    -- order_date: spread over past 2 years
    (CURRENT_DATE - (random() * 730)::int * INTERVAL '1 day')::date AS order_date,

    -- created_at: order_date plus random time during business hours
    (CURRENT_DATE - (random() * 730)::int * INTERVAL '1 day')
        + (8 + (random() * 14)::int) * INTERVAL '1 hour'
        + (random() * 59)::int * INTERVAL '1 minute' AS created_at,

    -- delivery_window: 1-7 days depending on shipping tier
    ((1 + (random() * 6)::int)::text || ' days')::interval AS delivery_window,

    -- product_metadata: realistic JSONB
    jsonb_build_object(
        'category',
        (ARRAY['electronics','clothing','books','home','sports',
               'beauty','toys','food','automotive','garden'
        ])[1 + (random() * 9)::int],
        'sku',        'SKU-' || lpad((random() * 99999)::int::text, 5, '0'),
        'quantity',   1 + (random() * 9)::int,
        'weight_kg',  ROUND((0.1 + random() * 19.9)::numeric, 2),
        'is_fragile', (random() < 0.2)
    ) AS product_metadata,

    -- promo_codes: 0-2 codes, NULL ~40%
    CASE
        WHEN random() < 0.4 THEN NULL
        WHEN random() < 0.7 THEN
            ARRAY[(ARRAY['SAVE10','WELCOME','SUMMER20','FLASH15','VIP30'])[1 + (random()*4)::int]]
        ELSE
            ARRAY[
                (ARRAY['SAVE10','WELCOME','SUMMER20','FLASH15','VIP30'])[1 + (random()*4)::int],
                (ARRAY['EXTRA5','LOYAL20','NEW25','REFER10','BUNDLE15'])[1 + (random()*4)::int]
            ]
    END AS promo_codes,

    -- order_status: weighted distribution
    (ARRAY[
        'delivered','delivered','delivered','delivered',  -- 40% delivered
        'shipped','shipped','shipped',                   -- 30% shipped
        'processing','processing',                       -- 20% processing
        'pending',                                       -- 7%  pending
        'cancelled',                                     -- 2%  cancelled
        'refunded'                                       -- 1%  refunded
    ])[1 + (random() * 11)::int] AS order_status,

    -- delivery coordinates: major Australian cities bounding box
    ROUND((-43.6 + random() * 15.8)::numeric, 6)::real AS delivery_lat,
    ROUND((113.3 + random() * 40.7)::numeric, 6)       AS delivery_lon

FROM generate_series(1, 1000);

-- =============================================================
-- Verification queries
-- =============================================================
SELECT
    COUNT(*)                                    AS total_rows,
    COUNT(DISTINCT customer_name)               AS unique_customers,
    ROUND(AVG(order_amount)::numeric, 2)        AS avg_order_amount,
    MIN(order_date)                             AS earliest_order,
    MAX(order_date)                             AS latest_order,
    COUNT(*) FILTER (WHERE customer_rating IS NULL) AS null_ratings,
    COUNT(*) FILTER (WHERE is_repeat_customer)  AS repeat_customers,
    COUNT(*) FILTER (WHERE promo_codes IS NULL) AS no_promo
FROM ecommerce.orders;

SELECT order_status, COUNT(*) AS cnt
FROM ecommerce.orders
GROUP BY order_status
ORDER BY cnt DESC;
