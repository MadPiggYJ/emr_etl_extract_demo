-- =============================================================
-- Module 1: Schema Design
-- Table: ecommerce.orders
-- 1000+ rows, 10+ distinct field types
-- =============================================================

CREATE SCHEMA IF NOT EXISTS ecommerce;

DROP TABLE IF EXISTS ecommerce.orders CASCADE;

CREATE TABLE ecommerce.orders (
    -- INTEGER: surrogate primary key
    order_id          SERIAL          PRIMARY KEY,

    -- UUID: business-facing order reference
    order_uuid        UUID            NOT NULL DEFAULT gen_random_uuid(),

    -- VARCHAR: customer name
    customer_name     VARCHAR(100)    NOT NULL,

    -- TEXT: free-form shipping address
    shipping_address  TEXT            NOT NULL,

    -- NUMERIC(precision,scale): monetary value
    order_amount      NUMERIC(12, 2)  NOT NULL CHECK (order_amount >= 0),

    -- SMALLINT: star rating 1-5
    customer_rating   SMALLINT        CHECK (customer_rating BETWEEN 1 AND 5),

    -- BOOLEAN: whether the order is a repeat purchase
    is_repeat_customer BOOLEAN        NOT NULL DEFAULT FALSE,

    -- DATE: calendar date of order placement
    order_date        DATE            NOT NULL,

    -- TIMESTAMP WITH TIME ZONE: exact event time
    created_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- INTERVAL: estimated delivery window
    delivery_window   INTERVAL        NOT NULL DEFAULT '3 days',

    -- JSONB: flexible product metadata
    product_metadata  JSONB,

    -- ARRAY of TEXT: applied promo codes
    promo_codes       TEXT[],

    -- ENUM-like: order lifecycle status
    order_status      VARCHAR(20)     NOT NULL
                          CHECK (order_status IN (
                              'pending','processing','shipped',
                              'delivered','cancelled','refunded'
                          )),

    -- REAL: geo-coordinates (latitude)
    delivery_lat      REAL,

    -- DOUBLE PRECISION: geo-coordinates (longitude)
    delivery_lon      DOUBLE PRECISION
);

-- Indexes for realistic query patterns
CREATE INDEX idx_orders_date        ON ecommerce.orders (order_date);
CREATE INDEX idx_orders_status      ON ecommerce.orders (order_status);
CREATE INDEX idx_orders_customer    ON ecommerce.orders (customer_name);
CREATE INDEX idx_orders_metadata    ON ecommerce.orders USING gin (product_metadata);

COMMENT ON TABLE ecommerce.orders IS
    'E-commerce orders table — demo dataset for EMR PySpark extraction exercise';
