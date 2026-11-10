-- No primary key on purpose: the raw file has exact duplicate rows and no unique ID column
CREATE TABLE online_retail (
    invoice        VARCHAR(20),
    stock_code     VARCHAR(20),
    description    TEXT,
    quantity       INTEGER,
    invoice_date   TIMESTAMP,
    price          NUMERIC(10,2),
    customer_id    INTEGER,
    country        VARCHAR(50)
);



---------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------
-- Checking how many values are missing in each column before doing any cleaning
SELECT
    COUNT(*) AS total_rows,
    COUNT(*) - COUNT(invoice) AS missing_invoice,
    COUNT(*) - COUNT(stock_code) AS missing_stock_code,
    COUNT(*) - COUNT(description) AS missing_description,
    COUNT(*) - COUNT(quantity) AS missing_quantity,
    COUNT(*) - COUNT(invoice_date) AS missing_invoice_date,
    COUNT(*) - COUNT(price) AS missing_price,
    COUNT(*) - COUNT(customer_id) AS missing_customer_id,
    COUNT(*) - COUNT(country) AS missing_country
FROM online_retail;


-- Counting exact duplicate rows: every column identical to another row.
-- cnt - 1 is the number of extra copies of each repeated row.
SELECT SUM(cnt - 1) AS extra_duplicate_rows
FROM (
    SELECT COUNT(*) AS cnt
    FROM online_retail
    GROUP BY invoice, stock_code, description, quantity,
             invoice_date, price, customer_id, country
    HAVING COUNT(*) > 1
) dup;


-- Splitting the duplicates into two groups: rows inside the 1-9 Dec 2010 window
-- (dates that appear in both source sheets) and rows everywhere else
SELECT
    CASE WHEN invoice_date >= '2010-12-01' AND invoice_date < '2010-12-10'
         THEN 'Inside overlap window (1-9 Dec 2010)'
         ELSE 'Outside overlap window' END AS duplicate_location,
    SUM(cnt - 1) AS extra_duplicate_rows
FROM (
    SELECT invoice_date, COUNT(*) AS cnt
    FROM online_retail
    GROUP BY invoice, stock_code, description, quantity,
             invoice_date, price, customer_id, country
    HAVING COUNT(*) > 1
) dup
GROUP BY 1;


-- Building a new table without exact duplicate rows; the raw table stays untouched
CREATE TABLE retail_clean AS
SELECT DISTINCT *
FROM online_retail;


SELECT COUNT(*) FROM retail_clean;


-- Counting rows that are not normal sales: cancellations, negative-quantity adjustments, and zero or negative prices
SELECT
    SUM(CASE WHEN invoice LIKE 'C%' THEN 1 ELSE 0 END) AS cancelled_invoice_rows,
    SUM(CASE WHEN quantity <= 0 THEN 1 ELSE 0 END) AS quantity_zero_or_negative,
    SUM(CASE WHEN quantity <= 0 AND invoice NOT LIKE 'C%' THEN 1 ELSE 0 END) AS negative_qty_not_cancelled,
    SUM(CASE WHEN price <= 0 THEN 1 ELSE 0 END) AS price_zero_or_negative
FROM retail_clean;


-- Checking what the negative-quantity rows (not cancelled invoices) actually are,
-- before excluding them from the sales analysis
SELECT
    COUNT(*) AS total_rows,
    SUM(CASE WHEN customer_id IS NULL THEN 1 ELSE 0 END) AS missing_customer_id,
    SUM(CASE WHEN description IS NULL THEN 1 ELSE 0 END) AS missing_description,
    SUM(CASE WHEN price = 0 THEN 1 ELSE 0 END) AS price_zero
FROM retail_clean
WHERE quantity <= 0 AND invoice NOT LIKE 'C%';


-- Real product codes contain digits (like 85048 or 79323P), so codes with no digit at all
-- are likely fees or adjustments rather than products
SELECT
    stock_code,
    MIN(description) AS sample_description,
    COUNT(*) AS row_count,
    ROUND(SUM(quantity * price), 0) AS total_value
FROM retail_clean
WHERE stock_code !~ '[0-9]'
GROUP BY stock_code
ORDER BY row_count DESC;


-- Building the sales-only table from retail_clean. A normal sale has a positive quantity and price,
-- is not on a cancelled invoice, and is a real product (not postage, fees or adjustments).
-- C2, TEST001 and TEST002 are excluded too: they contain digits, so the earlier check did not catch them.
-- A revenue column (quantity * price) is added for the later queries.
CREATE TABLE retail_sales AS
SELECT
    invoice,
    stock_code,
    description,
    quantity,
    invoice_date,
    price,
    quantity * price AS revenue,
    customer_id,
    country
FROM retail_clean
WHERE invoice NOT LIKE 'C%'
  AND quantity > 0
  AND price > 0
  AND stock_code NOT IN ('POST', 'DOT', 'M', 'm', 'D', 'S', 'BANK CHARGES',
                         'ADJUST', 'AMAZONFEE', 'CRUK', 'B',
                         'C2', 'TEST001', 'TEST002');


SELECT COUNT(*) FROM retail_sales;	


-- Checking whether the same stock code is stored in different letter cases (like 85123A and 85123a),
-- which would split one product into two in any GROUP BY stock_code
SELECT
    COUNT(DISTINCT stock_code) AS distinct_codes_as_stored,
    COUNT(DISTINCT UPPER(stock_code)) AS distinct_codes_ignoring_case
FROM retail_sales;


-- 170 stock codes differ only by letter case, which would split one product into two in
-- product-level queries. Converting all stock codes in the sales table to upper case.
UPDATE retail_sales
SET stock_code = UPPER(stock_code);


SELECT COUNT(DISTINCT stock_code) FROM retail_sales;


-- Checking how many descriptions have extra spaces at the start or end, or double spaces inside.
-- Extra spaces make the same product name look different in text comparisons and GROUP BY.
SELECT
    COUNT(*) AS total_rows,
    SUM(CASE WHEN description <> TRIM(description) THEN 1 ELSE 0 END) AS extra_space_at_ends,
    SUM(CASE WHEN description LIKE '%  %' THEN 1 ELSE 0 END) AS double_space_inside
FROM retail_sales;


-- Removing spaces at the start and end of each description, and turning double spaces inside
-- into a single space, so the same product name always looks the same.
UPDATE retail_sales
SET description = REGEXP_REPLACE(TRIM(description), '\s+', ' ', 'g');


SELECT
    SUM(CASE WHEN description <> TRIM(description) THEN 1 ELSE 0 END) AS extra_space_at_ends,
    SUM(CASE WHEN description LIKE '%  %' THEN 1 ELSE 0 END) AS double_space_inside
FROM retail_sales;


-- Re-running the space check after the update to confirm no description has extra spaces left
SELECT
    SUM(CASE WHEN description <> TRIM(description) THEN 1 ELSE 0 END) AS extra_space_at_ends,
    SUM(CASE WHEN description LIKE '%  %' THEN 1 ELSE 0 END) AS double_space_inside
FROM retail_sales;


-- Checking how many stock codes are stored under more than one description. If the same product
-- has several names, grouping by description would split it into several products.
SELECT
    COUNT(*) AS total_stock_codes,
    SUM(CASE WHEN desc_count > 1 THEN 1 ELSE 0 END) AS codes_with_multiple_descriptions
FROM (
    SELECT stock_code, COUNT(DISTINCT description) AS desc_count
    FROM retail_sales
    GROUP BY stock_code
) t;


-- 596 stock codes appear under more than one description. For each stock code, keeping its most
-- frequently used description (ties broken alphabetically) and applying it to all its rows.
-- The original names are still available in online_retail and retail_clean.
WITH name_counts AS (
    SELECT stock_code, description, COUNT(*) AS uses
    FROM retail_sales
    GROUP BY stock_code, description
),
best_name AS (
    SELECT stock_code, description
    FROM (
        SELECT stock_code, description,
               ROW_NUMBER() OVER (PARTITION BY stock_code ORDER BY uses DESC, description) AS rn
        FROM name_counts
    ) ranked
    WHERE rn = 1
)
UPDATE retail_sales s
SET description = b.description
FROM best_name b
WHERE s.stock_code = b.stock_code
  AND s.description <> b.description;


-- Re-running the multiple-description check after the update; every stock code should now have one name
SELECT
    COUNT(*) AS total_stock_codes,
    SUM(CASE WHEN desc_count > 1 THEN 1 ELSE 0 END) AS codes_with_multiple_descriptions
FROM (
    SELECT stock_code, COUNT(DISTINCT description) AS desc_count
    FROM retail_sales
    GROUP BY stock_code
) t;  


-- Listing every country with its row count to spot names that are not standard country names
SELECT country, COUNT(*) AS row_count
FROM retail_sales
GROUP BY country
ORDER BY country;


-- EIRE is the old name for Ireland and RSA is short for South Africa. Standardising both
-- so country-level analysis uses proper names.
UPDATE retail_sales
SET country = CASE country
                  WHEN 'EIRE' THEN 'Ireland'
                  WHEN 'RSA'  THEN 'South Africa'
              END
WHERE country IN ('EIRE', 'RSA');


-- Confirming the old names are gone and the new ones carry the expected row counts
SELECT country, COUNT(*) AS row_count
FROM retail_sales
WHERE country IN ('EIRE', 'RSA', 'Ireland', 'South Africa')
GROUP BY country;


-- Check large orders that were cancelled right after
-- The product revenue ranking showed two products with unusually large unit sales
-- (80,995 and 74,215 units). Checking whether those orders were reversed by looking
-- for matching cancellation invoices.
SELECT invoice, stock_code, quantity, invoice_date, customer_id
FROM retail_clean
WHERE stock_code IN ('23843', '23166')
  AND ABS(quantity) > 50000
ORDER BY invoice_date;


-- Building a table of cancelled product lines (negative quantities on invoices starting with C).
-- Fee and test codes are excluded as before. Stock codes are upper-cased to match retail_sales,
-- and each product takes the standardised name already used in retail_sales.
CREATE TABLE retail_cancellations AS
SELECT
    c.invoice,
    UPPER(c.stock_code) AS stock_code,
    n.description,
    c.quantity,
    c.invoice_date,
    c.price,
    c.quantity * c.price AS revenue,
    c.customer_id,
    CASE c.country WHEN 'EIRE' THEN 'Ireland'
                   WHEN 'RSA'  THEN 'South Africa'
                   ELSE c.country END AS country
FROM retail_clean c
JOIN (SELECT DISTINCT stock_code, description FROM retail_sales) n
  ON UPPER(c.stock_code) = n.stock_code
WHERE c.invoice LIKE 'C%'
  AND c.quantity < 0
  AND c.price > 0
  AND UPPER(c.stock_code) NOT IN ('POST', 'DOT', 'M', 'D', 'S', 'BANK CHARGES',
                                  'ADJUST', 'AMAZONFEE', 'CRUK', 'B',
                                  'C2', 'TEST001', 'TEST002');


-- Checking the size and total value of the cancellations table
SELECT COUNT(*) AS cancelled_lines, ROUND(SUM(revenue), 0) AS cancelled_value
FROM retail_cancellations;	


-- Combining sales and cancellations into one view, so net revenue (sales minus cancelled value)
-- can be calculated in a single query. Cancelled lines carry negative quantity and revenue.
CREATE VIEW retail_net AS
SELECT invoice, stock_code, description, quantity, invoice_date, price, revenue, customer_id, country
FROM retail_sales
UNION ALL
SELECT invoice, stock_code, description, quantity, invoice_date, price, revenue, customer_id, country
FROM retail_cancellations;


-- Net revenue should equal gross sales plus the (negative) cancelled value
SELECT
    (SELECT ROUND(SUM(revenue), 0) FROM retail_sales) AS gross_revenue,
    (SELECT ROUND(SUM(revenue), 0) FROM retail_cancellations) AS cancelled_value,
    (SELECT ROUND(SUM(revenue), 0) FROM retail_net) AS net_revenue;


-- ---------------------------------------------------------------------
-- Cleaning summary (Steps 1 to 19)
-- ---------------------------------------------------------------------
-- online_retail        : raw data, never changed
-- retail_clean         : raw data with exact duplicate rows removed
-- retail_sales         : gross sales only (no cancellations, fees or adjustments)
-- retail_cancellations : cancelled product lines, with negative quantity and revenue
-- retail_net (view)    : sales and cancellations together, used for net revenue


------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------

-- Q1. What does the cleaned data cover: orders, customers, products, countries, revenue and time period?
SELECT
    (SELECT COUNT(DISTINCT invoice) FROM retail_sales) AS total_orders,
    (SELECT COUNT(DISTINCT customer_id) FROM retail_sales) AS identified_customers,
    (SELECT COUNT(DISTINCT stock_code) FROM retail_sales) AS products,
    (SELECT COUNT(DISTINCT country) FROM retail_sales) AS countries,
    (SELECT ROUND(SUM(revenue), 0) FROM retail_sales) AS gross_revenue,
    (SELECT ROUND(-SUM(revenue), 0) FROM retail_cancellations) AS cancelled_value,
    (SELECT ROUND(SUM(revenue), 0) FROM retail_net) AS net_revenue,
    (SELECT MIN(invoice_date)::date FROM retail_sales) AS first_sale,
    (SELECT MAX(invoice_date)::date FROM retail_sales) AS last_sale;


-- Q2. How have monthly orders and net revenue trended over the two years?
SELECT
    DATE_TRUNC('month', invoice_date)::date AS month,
    COUNT(DISTINCT CASE WHEN revenue > 0 THEN invoice END) AS orders,
    ROUND(SUM(revenue), 0) AS net_revenue
FROM retail_net
GROUP BY 1
ORDER BY 1;	


-- Q3. Which countries generate the most net revenue, and what share of the total does each bring?
SELECT
    country,
    COUNT(DISTINCT CASE WHEN revenue > 0 THEN invoice END) AS orders,
    ROUND(SUM(revenue), 0) AS net_revenue,
    ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 1) AS pct_of_total
FROM retail_net
GROUP BY country
ORDER BY net_revenue DESC
LIMIT 10;


-- Q4. Which 10 products generate the most net revenue, and how many units were sold after cancellations?
SELECT
    stock_code,
    description,
    SUM(quantity) AS net_units_sold,
    ROUND(SUM(revenue), 0) AS net_revenue,
    ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 2) AS pct_of_total
FROM retail_net
GROUP BY stock_code, description
ORDER BY net_revenue DESC
LIMIT 10;


-- Q5. What share of identified customers are repeat buyers, and how much net revenue do they bring?
WITH customer_orders AS (
    SELECT
        customer_id,
        COUNT(DISTINCT CASE WHEN revenue > 0 THEN invoice END) AS orders,
        SUM(revenue) AS net_revenue
    FROM retail_net
    WHERE customer_id IS NOT NULL
    GROUP BY customer_id
)
SELECT
    CASE WHEN orders = 1 THEN 'One-time buyer' ELSE 'Repeat buyer' END AS customer_type,
    COUNT(*) AS customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_customers,
    ROUND(SUM(net_revenue), 0) AS net_revenue,
    ROUND(100.0 * SUM(net_revenue) / SUM(SUM(net_revenue)) OVER (), 1) AS pct_of_revenue
FROM customer_orders
WHERE orders >= 1
GROUP BY 1;


-- Q6. Who are the top 10 customers by net revenue, and how much of the identified total do they bring?
SELECT
    customer_id,
    COUNT(DISTINCT CASE WHEN revenue > 0 THEN invoice END) AS orders,
    ROUND(SUM(revenue), 0) AS net_revenue,
    ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 1) AS pct_of_identified_revenue
FROM retail_net
WHERE customer_id IS NOT NULL
GROUP BY customer_id
ORDER BY net_revenue DESC
LIMIT 10;


-- Q7. How can customers be grouped by how recently and how often they buy (RFM-style segments),
-- and how much net revenue does each group bring?
WITH sales_stats AS (
    SELECT customer_id,
           MAX(invoice_date)::date AS last_purchase,
           COUNT(DISTINCT invoice) AS frequency
    FROM retail_sales
    WHERE customer_id IS NOT NULL
    GROUP BY customer_id
),
money AS (
    SELECT customer_id, SUM(revenue) AS net_revenue
    FROM retail_net
    WHERE customer_id IS NOT NULL
    GROUP BY customer_id
),
rfm AS (
    SELECT s.customer_id,
           DATE '2011-12-10' - s.last_purchase AS recency_days,
           s.frequency,
           m.net_revenue
    FROM sales_stats s
    JOIN money m ON s.customer_id = m.customer_id
)
SELECT
    CASE
        WHEN recency_days <= 90 AND frequency >= 5 THEN '1. Champions'
        WHEN recency_days <= 90 THEN '2. Recent customers'
        WHEN recency_days <= 365 AND frequency >= 5 THEN '3. At risk'
        WHEN recency_days <= 365 THEN '4. Cooling down'
        ELSE '5. Lost'
    END AS segment,
    COUNT(*) AS customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_customers,
    ROUND(SUM(net_revenue), 0) AS net_revenue,
    ROUND(100.0 * SUM(net_revenue) / SUM(SUM(net_revenue)) OVER (), 1) AS pct_of_revenue
FROM rfm
GROUP BY 1
ORDER BY 1;


-- Q8. What share of gross revenue is cancelled each month?
SELECT
    m.month,
    ROUND(m.gross_revenue, 0) AS gross_revenue,
    ROUND(COALESCE(c.cancelled_value, 0), 0) AS cancelled_value,
    ROUND(100.0 * COALESCE(c.cancelled_value, 0) / m.gross_revenue, 1) AS cancelled_pct
FROM (
    SELECT DATE_TRUNC('month', invoice_date)::date AS month, SUM(revenue) AS gross_revenue
    FROM retail_sales
    GROUP BY 1
) m
LEFT JOIN (
    SELECT DATE_TRUNC('month', invoice_date)::date AS month, -SUM(revenue) AS cancelled_value
    FROM retail_cancellations
    GROUP BY 1
) c ON m.month = c.month
ORDER BY m.month;


-- Q9. Which products have the highest cancellation ratio, measured in orders rather than units?
-- Counting orders (not units) stops one huge bulk order from dominating the ranking.
-- Only products that appear in at least 100 orders are included.
SELECT
    s.stock_code,
    s.description,
    s.orders_sold,
    COALESCE(c.cancelled_orders, 0) AS cancelled_orders,
    ROUND(100.0 * COALESCE(c.cancelled_orders, 0) / s.orders_sold, 1) AS cancelled_pct
FROM (
    SELECT stock_code, description, COUNT(DISTINCT invoice) AS orders_sold
    FROM retail_sales
    GROUP BY stock_code, description
) s
LEFT JOIN (
    SELECT stock_code, COUNT(DISTINCT invoice) AS cancelled_orders
    FROM retail_cancellations
    GROUP BY stock_code
) c ON s.stock_code = c.stock_code
WHERE s.orders_sold >= 100
ORDER BY cancelled_pct DESC
LIMIT 10;


-- Q10. On which days of the week do customers place orders, and how much gross revenue does each day bring?
SELECT
    EXTRACT(ISODOW FROM invoice_date) AS day_number,
    TRIM(TO_CHAR(invoice_date, 'Day')) AS day_name,
    COUNT(DISTINCT invoice) AS orders,
    ROUND(SUM(revenue), 0) AS revenue,
    ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 1) AS pct_of_revenue
FROM retail_sales
GROUP BY 1, 2
ORDER BY 1;


-- Q11. Of the customers who made their first purchase in each quarter, what share bought again within 90 days?
-- Customers whose first purchase is after 9 Sep 2011 are left out, because the data ends on 9 Dec 2011
-- and they would not have a full 90 days to come back.
WITH first_purchase AS (
    SELECT customer_id, MIN(invoice_date) AS first_date
    FROM retail_sales
    WHERE customer_id IS NOT NULL
    GROUP BY customer_id
),
repeat_flag AS (
    SELECT f.customer_id,
           f.first_date,
           MAX(CASE WHEN s.invoice_date::date > f.first_date::date
                     AND s.invoice_date::date <= f.first_date::date + 90
                    THEN 1 ELSE 0 END) AS bought_again
    FROM first_purchase f
    JOIN retail_sales s ON s.customer_id = f.customer_id
    GROUP BY f.customer_id, f.first_date
)
SELECT
    DATE_TRUNC('quarter', first_date)::date AS cohort_quarter,
    COUNT(*) AS new_customers,
    SUM(bought_again) AS bought_again_in_90_days,
    ROUND(100.0 * SUM(bought_again) / COUNT(*), 1) AS repeat_rate_pct
FROM repeat_flag
WHERE first_date < DATE '2011-09-10'
GROUP BY 1
ORDER BY 1;





	


								  
 











