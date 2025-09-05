-- create airbnb database
CREATE DATABASE airbnb;
-- work with airbnb database
USE airbnb;

/**********************************************************************************************
 Airbnb-Reservation System — Extended Schema
 Covers:
 - Users, Properties, Amenities (M:N), Normalized Locations
 - Search tracking and booking popularity
 - Dynamic pricing (base/seasonal/special) + nightly snapshots so historical bookings never change
 - Reservations, Payments
 - Property-level expenses
 - Double-entry accounting ledger (accounts, journal, lines) with property tagging
 - Tax rules & captured tax snapshots for compliance
**********************************************************************************************/

-- For idempotent rebuilds in dev (optional)
-- SET FOREIGN_KEY_CHECKS = 0;
-- DROP TABLE IF EXISTS journal_lines, journal_entries, accounts, expenses, tax_returns, tax_rules,
--   payment_allocations, payments, reservation_nights, reservations, price_overrides, seasonal_prices,
--   property_amenities, amenities, properties, locations, users, search_logs;
-- SET FOREIGN_KEY_CHECKS = 1;


/**********************************************************************************************
 TABLE: users
 ----------------------------------------------------------------------------------------------
 - Unified table for hosts & guests (and admins).
**********************************************************************************************/
CREATE TABLE IF NOT EXISTS users (
    user_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL,
    email VARCHAR(120) NOT NULL UNIQUE,
    phone VARCHAR(25),
    password_hash VARCHAR(255) NOT NULL,
    user_type ENUM('host','guest','admin') NOT NULL DEFAULT 'guest',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;


 /**********************************************************************************************
 TABLE: locations
 ----------------------------------------------------------------------------------------------
 - Normalized location hierarchy for properties and reporting.
 - Keep it simple: country -> state/region -> city -> neighborhood (nullable).
**********************************************************************************************/


CREATE TABLE IF NOT EXISTS locations (
    location_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    country VARCHAR(100) NOT NULL,
    region VARCHAR(100),          -- state/province/region
    city VARCHAR(100) NOT NULL,
    neighborhood VARCHAR(120),    -- optional finer granularity
    postal_code VARCHAR(20),
    latitude DECIMAL(9,6),        -- optional geo
    longitude DECIMAL(9,6),

    -- generated columns (replace NULL with '')
    region_norm VARCHAR(100) GENERATED ALWAYS AS (IFNULL(region, '')) STORED,
    neighborhood_norm VARCHAR(120) GENERATED ALWAYS AS (IFNULL(neighborhood, '')) STORED,
    postal_code_norm VARCHAR(20) GENERATED ALWAYS AS (IFNULL(postal_code, '')) STORED,

    UNIQUE KEY uq_loc (country, region_norm, city, neighborhood_norm, postal_code_norm)
) ENGINE=InnoDB;
 /**********************************************************************************************
 TABLE: properties
 ----------------------------------------------------------------------------------------------
 - Listings created by hosts and linked to a location.
 - price_per_night acts as a BASE rate; other layers can override per date.
**********************************************************************************************/
CREATE TABLE IF NOT EXISTS properties (
    property_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    host_id BIGINT UNSIGNED NOT NULL,
    location_id BIGINT UNSIGNED NOT NULL,
    title VARCHAR(150) NOT NULL,
    description TEXT,
    address_line VARCHAR(255),
    max_guests INT NOT NULL,
    base_price_per_night DECIMAL(10,2) NOT NULL,  -- base rate
    currency CHAR(3) NOT NULL DEFAULT 'USD',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_prop_host FOREIGN KEY (host_id) REFERENCES users(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_prop_location FOREIGN KEY (location_id) REFERENCES locations(location_id) ON DELETE RESTRICT
) ENGINE=InnoDB;


 /**********************************************************************************************
 TABLE: amenities
 ----------------------------------------------------------------------------------------------
 - Catalog of amenities (e.g., WiFi, Parking, Pool, AC).
**********************************************************************************************/
CREATE TABLE IF NOT EXISTS amenities (
    amenity_id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(80) NOT NULL UNIQUE,
    icon VARCHAR(80)    -- optional UI hint
) ENGINE=InnoDB;


 /**********************************************************************************************
 TABLE: property_amenities (M:N)
 ----------------------------------------------------------------------------------------------
 - Bridge table linking properties and amenities.
**********************************************************************************************/
CREATE TABLE IF NOT EXISTS property_amenities (
    property_id BIGINT UNSIGNED NOT NULL,
    amenity_id INT UNSIGNED NOT NULL,
    PRIMARY KEY (property_id, amenity_id),
    CONSTRAINT fk_pa_property FOREIGN KEY (property_id) REFERENCES properties(property_id) ON DELETE CASCADE,
    CONSTRAINT fk_pa_amenity FOREIGN KEY (amenity_id) REFERENCES amenities(amenity_id) ON DELETE CASCADE
) ENGINE=InnoDB;


 /**********************************************************************************************
 TABLE: search_logs
 ----------------------------------------------------------------------------------------------
 - Tracks searches to compute "most searched" listings and demand signals.
 - Record top-N listing IDs shown (or clicked) to users for popularity & analytics.
**********************************************************************************************/
CREATE TABLE IF NOT EXISTS search_logs (
    search_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT UNSIGNED,            -- nullable for anonymous
    searched_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    check_in DATE,
    check_out DATE,
    guests INT,
    city VARCHAR(100),
    region VARCHAR(100),
    country VARCHAR(100),
    keywords VARCHAR(255),
    shown_property_ids JSON,           -- list of property IDs returned (optional)
    clicked_property_id BIGINT UNSIGNED, -- which one the user clicked (optional)
    INDEX idx_search_time (searched_at),
    INDEX idx_clicked (clicked_property_id),
    CONSTRAINT fk_sl_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE SET NULL
) ENGINE=InnoDB;


 /**********************************************************************************************
 PRICING MODEL (LAYERED)
 ----------------------------------------------------------------------------------------------
 1) properties.base_price_per_night (base)
 2) seasonal_prices: date-range overrides
 3) price_overrides: per-day specials (highest priority)
 Final nightly price is determined at booking time and SNAPSHOTTED in reservation_nights.
**********************************************************************************************/

 /**********************************************************************************************
 TABLE: seasonal_prices
 ----------------------------------------------------------------------------------------------
 - Seasonal date-range pricing per property.
 - Example: High season in Dec: 150.00 instead of base 100.00
**********************************************************************************************/
CREATE TABLE IF NOT EXISTS seasonal_prices (
    seasonal_price_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    property_id BIGINT UNSIGNED NOT NULL,
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,
    price_per_night DECIMAL(10,2) NOT NULL,
    CHECK (start_date <= end_date),
    INDEX idx_sp_range (property_id, start_date, end_date),
    CONSTRAINT fk_sp_property FOREIGN KEY (property_id) REFERENCES properties(property_id) ON DELETE CASCADE
) ENGINE=InnoDB;


 /**********************************************************************************************
 TABLE: price_overrides
 ----------------------------------------------------------------------------------------------
 - Highest-priority per-day override (e.g., event night surge or discount).
**********************************************************************************************/
CREATE TABLE IF NOT EXISTS price_overrides (
    override_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    property_id BIGINT UNSIGNED NOT NULL,
    stay_date DATE NOT NULL,                         -- specific day
    price_per_night DECIMAL(10,2) NOT NULL,
    UNIQUE KEY uq_override (property_id, stay_date),
    INDEX idx_po (property_id, stay_date),
    CONSTRAINT fk_po_property FOREIGN KEY (property_id) REFERENCES properties(property_id) ON DELETE CASCADE
) ENGINE=InnoDB;


 /**********************************************************************************************
 TABLE: reservations
 ----------------------------------------------------------------------------------------------
 - Booking header (guest + property + overall status).
 - Night-by-night financials are stored in reservation_nights to freeze historical prices.
**********************************************************************************************/
CREATE TABLE IF NOT EXISTS reservations (
    reservation_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    property_id BIGINT UNSIGNED NOT NULL,
    guest_id BIGINT UNSIGNED NOT NULL,
    check_in DATE NOT NULL,
    check_out DATE NOT NULL,         -- exclusive end date
    status ENUM('pending','confirmed','cancelled','completed') NOT NULL DEFAULT 'pending',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    -- convenience totals (optional, can be derived from reservation_nights)
    subtotal_amount DECIMAL(12,2) DEFAULT 0.00,
    tax_amount DECIMAL(12,2) DEFAULT 0.00,
    total_amount DECIMAL(12,2) DEFAULT 0.00,
    INDEX idx_resv_property_dates (property_id, check_in, check_out),
    INDEX idx_resv_guest (guest_id),
    CONSTRAINT fk_resv_property FOREIGN KEY (property_id) REFERENCES properties(property_id) ON DELETE CASCADE,
    CONSTRAINT fk_resv_guest FOREIGN KEY (guest_id) REFERENCES users(user_id) ON DELETE CASCADE,
    CHECK (check_in < check_out)
) ENGINE=InnoDB;


 /**********************************************************************************************
 TABLE: reservation_nights  (PRICE SNAPSHOT)
 ----------------------------------------------------------------------------------------------
 - One row per reserved night.
 - Captures the FINAL nightly_price, fees, and tax as of booking time so future price changes
   DO NOT affect historical bookings.
 - This is the key to your "price change shouldn’t alter past rates" requirement.
**********************************************************************************************/

CREATE TABLE IF NOT EXISTS reservation_nights (
    reservation_night_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    reservation_id BIGINT UNSIGNED NOT NULL,
    property_id BIGINT UNSIGNED NOT NULL,
    stay_date DATE NOT NULL,
    nightly_price DECIMAL(10,2) NOT NULL,    -- frozen at booking time
    cleaning_fee DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    service_fee DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    tax_rate_applied DECIMAL(7,4) NOT NULL DEFAULT 0.0000,  -- snapshot of tax %
    tax_amount DECIMAL(10,2) NOT NULL DEFAULT 0.00,         -- computed & frozen

    -- must declare type for generated column
    total_for_night DECIMAL(10,2) 
        GENERATED ALWAYS AS (nightly_price + cleaning_fee + service_fee + tax_amount) STORED,

    UNIQUE KEY uq_resv_night (reservation_id, stay_date),
    INDEX idx_rn_property_date (property_id, stay_date),

    CONSTRAINT fk_rn_reservation FOREIGN KEY (reservation_id) REFERENCES reservations(reservation_id) ON DELETE CASCADE,
    CONSTRAINT fk_rn_property FOREIGN KEY (property_id) REFERENCES properties(property_id) ON DELETE CASCADE
) ENGINE=InnoDB;


 /**********************************************************************************************
 TABLE: payments
 ----------------------------------------------------------------------------------------------
 - Records cash in (from guest) or refunds (negative amounts or status).
**********************************************************************************************/
CREATE TABLE IF NOT EXISTS payments (
    payment_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    payer_user_id BIGINT UNSIGNED,                    -- guest or third-party
    method ENUM('credit_card','debit_card','paypal','mobile_money','bank_transfer') NOT NULL,
    amount DECIMAL(12,2) NOT NULL,                    -- positive = received; negative = refund out
    currency CHAR(3) NOT NULL DEFAULT 'USD',
    status ENUM('pending','completed','failed','refunded') NOT NULL DEFAULT 'pending',
    processed_at TIMESTAMP NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_pay_status (status, created_at),
    CONSTRAINT fk_pay_user FOREIGN KEY (payer_user_id) REFERENCES users(user_id) ON DELETE SET NULL
) ENGINE=InnoDB;


 /**********************************************************************************************
 TABLE: payment_allocations
 ----------------------------------------------------------------------------------------------
 - Allocates a single payment across one or more reservations (partial payments supported).
**********************************************************************************************/
CREATE TABLE IF NOT EXISTS payment_allocations (
    allocation_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    payment_id BIGINT UNSIGNED NOT NULL,
    reservation_id BIGINT UNSIGNED NOT NULL,
    amount_applied DECIMAL(12,2) NOT NULL,
    UNIQUE KEY uq_pay_res (payment_id, reservation_id),
    CONSTRAINT fk_pa_payment FOREIGN KEY (payment_id) REFERENCES payments(payment_id) ON DELETE CASCADE,
    CONSTRAINT fk_pa_reservation FOREIGN KEY (reservation_id) REFERENCES reservations(reservation_id) ON DELETE CASCADE
) ENGINE=InnoDB;


 /**********************************************************************************************
 TABLE: expenses
 ----------------------------------------------------------------------------------------------
 - Direct property-level operating expenses (cash out), e.g., cleaning, maintenance, utilities.
 - These feed both the P&L and the accounting ledger.
**********************************************************************************************/
CREATE TABLE IF NOT EXISTS expenses (
    expense_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    property_id BIGINT UNSIGNED NOT NULL,
    vendor_name VARCHAR(150),
    category ENUM('cleaning','maintenance','utilities','supplies','tax','insurance','other') NOT NULL,
    description VARCHAR(255),
    expense_date DATE NOT NULL,
    amount DECIMAL(12,2) NOT NULL,
    currency CHAR(3) NOT NULL DEFAULT 'USD',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_exp_prop_date (property_id, expense_date),
    CONSTRAINT fk_exp_property FOREIGN KEY (property_id) REFERENCES properties(property_id) ON DELETE CASCADE
) ENGINE=InnoDB;


 /**********************************************************************************************
 DOUBLE-ENTRY LEDGER
 ----------------------------------------------------------------------------------------------
 - accounts: Chart of accounts
 - journal_entries: Header with date/memo
 - journal_lines: Debit/Credit lines, tagged to property when relevant
 Notes:
 - Enforce sum(debits) == sum(credits) per entry at application layer or via triggers (optional).
**********************************************************************************************/

CREATE TABLE IF NOT EXISTS accounts (
    account_id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    code VARCHAR(20) NOT NULL UNIQUE,
    name VARCHAR(120) NOT NULL,
    type ENUM('asset','liability','equity','income','expense','tax') NOT NULL,
    is_active TINYINT(1) NOT NULL DEFAULT 1
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS journal_entries (
    journal_entry_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    entry_date DATE NOT NULL,
    memo VARCHAR(255),
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS journal_lines (
    journal_line_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    journal_entry_id BIGINT UNSIGNED NOT NULL,
    account_id INT UNSIGNED NOT NULL,
    property_id BIGINT UNSIGNED,                 -- optional: tie line to a property for P&L by property
    description VARCHAR(255),
    debit DECIMAL(14,2) NOT NULL DEFAULT 0.00,
    credit DECIMAL(14,2) NOT NULL DEFAULT 0.00,
    CONSTRAINT fk_jl_entry FOREIGN KEY (journal_entry_id) REFERENCES journal_entries(journal_entry_id) ON DELETE CASCADE,
    CONSTRAINT fk_jl_account FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE RESTRICT,
    CONSTRAINT fk_jl_property FOREIGN KEY (property_id) REFERENCES properties(property_id) ON DELETE SET NULL,
    CHECK (NOT (debit > 0 AND credit > 0)),      -- cannot have both on same line
    CHECK (debit >= 0 AND credit >= 0)
) ENGINE=InnoDB;


 /**********************************************************************************************
 TAX COMPLIANCE
 ----------------------------------------------------------------------------------------------
 - tax_rules: current tax policy per location (simple rate model here)
 - tax_returns: record of filed/paid returns per period for audit trail
 - Booking-time tax snapshots are stored in reservation_nights (rate/amount) to preserve history.
**********************************************************************************************/

CREATE TABLE IF NOT EXISTS tax_rules (
    tax_rule_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    location_id BIGINT UNSIGNED NOT NULL,
    effective_from DATE NOT NULL,
    effective_to DATE,                              -- NULL = open-ended
    tax_name VARCHAR(120) NOT NULL,                 -- e.g., "Occupancy Tax"
    rate DECIMAL(7,4) NOT NULL,                     -- 0.1200 = 12.00%
    is_percentage TINYINT(1) NOT NULL DEFAULT 1,    -- support flat-fee in future
    UNIQUE KEY uq_tax_rule (location_id, tax_name, effective_from),
    CONSTRAINT fk_tr_location FOREIGN KEY (location_id) REFERENCES locations(location_id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS tax_returns (
    tax_return_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    location_id BIGINT UNSIGNED NOT NULL,
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    tax_name VARCHAR(120) NOT NULL,
    declared_amount DECIMAL(14,2) NOT NULL,
    filed_on DATE NOT NULL,
    paid_on DATE,
    reference_no VARCHAR(120),
    CONSTRAINT fk_taxret_location FOREIGN KEY (location_id) REFERENCES locations(location_id) ON DELETE CASCADE
) ENGINE=InnoDB;


 /**********************************************************************************************
 VIEWS — INSIGHTS & REPORTS
 ----------------------------------------------------------------------------------------------
 - v_top_searched_properties: rank by clicks (proxy for interest)
 - v_top_booked_properties: rank by nights booked
 - v_property_revenue: revenue by property
 - v_property_expense: expense by property
 - v_property_pnl: Profit & Loss by property
**********************************************************************************************/

-- Most searched (clicks) in the last 90 days
CREATE OR REPLACE VIEW v_top_searched_properties AS
SELECT
    sl.clicked_property_id AS property_id,
    COUNT(*) AS clicks_90d
FROM search_logs sl
WHERE sl.clicked_property_id IS NOT NULL
  AND sl.searched_at >= (CURRENT_DATE - INTERVAL 90 DAY)
GROUP BY sl.clicked_property_id
ORDER BY clicks_90d DESC;

-- Most booked by nights in the last 90 days
CREATE OR REPLACE VIEW v_top_booked_properties AS
SELECT
    rn.property_id,
    COUNT(*) AS nights_booked_90d
FROM reservation_nights rn
JOIN reservations r ON r.reservation_id = rn.reservation_id
WHERE r.status IN ('confirmed','completed')
  AND rn.stay_date >= (CURRENT_DATE - INTERVAL 90 DAY)
GROUP BY rn.property_id
ORDER BY nights_booked_90d DESC;

-- Revenue (sum of per-night totals) by property and month
CREATE OR REPLACE VIEW v_property_revenue AS
SELECT
    rn.property_id,
    DATE_FORMAT(rn.stay_date, '%Y-%m-01') AS revenue_month,
    SUM(rn.nightly_price + rn.cleaning_fee + rn.service_fee) AS revenue_excl_tax,
    SUM(rn.tax_amount) AS tax_collected,
    SUM(rn.total_for_night) AS revenue_incl_tax
FROM reservation_nights rn
JOIN reservations r ON r.reservation_id = rn.reservation_id
WHERE r.status IN ('confirmed','completed')
GROUP BY rn.property_id, DATE_FORMAT(rn.stay_date, '%Y-%m-01');

-- Expenses by property and month
CREATE OR REPLACE VIEW v_property_expense AS
SELECT
    e.property_id,
    DATE_FORMAT(e.expense_date, '%Y-%m-01') AS expense_month,
    SUM(e.amount) AS total_expense
FROM expenses e
GROUP BY e.property_id, DATE_FORMAT(e.expense_date, '%Y-%m-01');

-- P&L by property and month (simple join of the two views)
CREATE OR REPLACE VIEW v_property_pnl AS
SELECT
    rev.property_id,
    rev.revenue_month AS period_month,
    rev.revenue_excl_tax,
    rev.tax_collected,
    COALESCE(exp.total_expense, 0.00) AS total_expense,
    (rev.revenue_excl_tax - COALESCE(exp.total_expense, 0.00)) AS profit_before_tax
FROM v_property_revenue rev
LEFT JOIN v_property_expense exp
  ON exp.property_id = rev.property_id
 AND exp.expense_month = rev.revenue_month;


 /**********************************************************************************************
 INDEXING HINTS
 ----------------------------------------------------------------------------------------------
 - Add compound indexes that match your hottest queries (date ranges, property lists).
**********************************************************************************************/
CREATE INDEX idx_resv_guest_dates ON reservations (guest_id, check_in, check_out);
CREATE INDEX idx_rn_prop_month ON reservation_nights (property_id, stay_date);
