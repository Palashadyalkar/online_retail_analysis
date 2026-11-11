# Online Retail Sales and Customer Analysis with SQL

A SQL project on the Online Retail II dataset, about 1 million transaction lines from a UK-based online gift and home decor retailer. The raw data is messy, so most of the work went into cleaning it properly in PostgreSQL before answering 11 business questions on revenue, customers, products, and cancellations.

## Tools used
PostgreSQL, pgAdmin, SQL

## The problem

A retailer wants to know how the business is really doing: how much it sells, who buys, which customers matter most, and where money is lost to cancellations. The transaction log is not ready for that. It has duplicate rows, cancelled invoices mixed in with sales, postage and fees recorded like products, and a fifth of the lines have no customer ID. If any of that stays in, revenue and customer numbers come out wrong. So this project does two things: clean the data step by step, then answer the questions on the cleaned data.

## Dataset

- Source: UCI Machine Learning Repository, Online Retail II
- Link: https://archive.ics.uci.edu/dataset/502/online+retail+ii
- Period: 1 Dec 2009 to 9 Dec 2011
- Size: 1,067,371 rows, 8 columns

| Column | Meaning |
|---|---|
| invoice | Invoice number (starts with C if the invoice is a cancellation) |
| stock_code | Product code |
| description | Product name |
| quantity | Units on that line (negative for cancellations) |
| invoice_date | Date and time of the invoice |
| price | Price per unit |
| customer_id | Customer ID (missing on many lines) |
| country | Customer country |

The dataset does not state a currency, so amounts are shown as plain numbers.

## Files in this repository

| File | What it is |
|---|---|
| `online_retail_analysis.sql` | Table setup, all cleaning steps with check queries, and the 11 analysis questions |
| `README.md` | This file |

**The raw data file is not in this repository.** It is about 90 MB, which is over GitHub's upload limit, so please download it from the link above.

## How to run this project

1. Download `online_retail_II.xlsx` from the UCI link. It has two sheets, one for each year.
2. Combine both sheets into one CSV with the 8 columns in the order above. Nothing else is changed, except that Customer ID is written as a whole number (13085, not 13085.0) so PostgreSQL can load it. This is a file format step, not cleaning.
3. Create a database called `online_retail_analysis` and run the `CREATE TABLE` statement at the top of `online_retail_analysis.sql`.
4. Import the CSV into the table (pgAdmin: right-click the table, Import/Export Data, format csv, header on, encoding UTF8).
5. Run the rest of the file in order: cleaning first, then Q1 to Q11.

The script can be run again safely. Tables use `CREATE TABLE IF NOT EXISTS` and the view uses `CREATE OR REPLACE`, so a second run does not throw "already exists" errors. The side effect is that an existing table is skipped, not rebuilt, so to rebuild a table from scratch, drop it first.

Numbers to expect while running:

| Check | Expected |
|---|---|
| Rows in `online_retail` after import | 1,067,371 |
| Exact duplicate rows found | 34,335 |
| Rows in `retail_clean` | 1,033,036 |
| Rows in `retail_sales` | 1,003,420 |
| Distinct stock codes after cleaning | 4,733 |
| Lines in `retail_cancellations` | 17,894 (value -716,232) |
| Net revenue | 18,930,117 |

## Data cleaning

All cleaning is done in SQL. The raw table is never changed. Each stage builds a new table from the one before, so every step can be traced back.

| Table | What it holds |
|---|---|
| online_retail | The raw data, untouched |
| retail_clean | Raw data with exact duplicate rows removed |
| retail_sales | Gross sales only: no cancellations, fees, or adjustments |
| retail_cancellations | Cancelled product lines, with negative quantity and revenue |
| retail_net (view) | Sales and cancellations together, used for net revenue |

**1. Missing values.** 243,007 rows (22.8%) have no customer ID and 4,382 have no description. I kept the rows without a customer ID, because they are real sales and still count for revenue and product analysis. They are only left out of customer-level questions.

**2. Duplicate rows.** 34,335 rows were exact copies of another row. Before deleting, I checked where they came from. 22,844 of them fall between 1 and 9 Dec 2010, the nine days that appear in both Excel sheets, so that data was simply loaded twice. The other 11,491 are the same product line repeated inside one invoice in the same minute. I treated those as repeated entries too, which is an assumption (see Limitations). Duplicates were removed into a new table, `retail_clean`.

**3. Rows that are not sales.** From `retail_clean` I built `retail_sales` and left out:
- Cancelled invoices (19,104 lines on invoices starting with C). These are not deleted, they go into their own table (see step 7).
- 3,393 lines with negative quantity that are not cancellations. Every one has no customer and a zero price, and most have no description or a note like "damaged" or "check". These are stock write-offs, not sales.
- Lines with a zero or negative price.
- Non-product codes: POST and DOT (postage), M (manual entries), D (discount), S (samples), BANK CHARGES, ADJUST, AMAZONFEE, CRUK (commission), B (bad debt), plus C2 (carriage), TEST001, and TEST002. Real product codes contain digits, so I listed every code with no digit and checked each one. A few real products in that list (like the party bag codes) were kept. Leaving the fee codes in would have moved revenue by hundreds of thousands, for example AMAZONFEE alone is about -221,000.

**4. Stock codes.** The same product was sometimes stored as `85123A` and sometimes as `85123a`. 170 codes were split this way (4,903 codes became 4,733), which would cut some products in two in any grouping. All codes were converted to upper case.

**5. Descriptions.** 202,947 descriptions had extra spaces at the start or end and 50,490 had double spaces inside. These were cleaned. I then found 596 stock codes that appear under more than one name (for example one doormat sold under four names). The same stock code means the same product, so each code now uses its most common name. The original names are still in the raw and clean tables.

**6. Countries.** EIRE was changed to Ireland and RSA to South Africa. Channel Islands, European Community, West Indies, Unspecified, and Korea were left as they are, because the data does not say exactly which country they mean.

**7. Cancellations and net revenue.** This turned out to be the most important fix. The product revenue ranking first showed two products with unusually large unit sales (80,995 and 74,215 units). Checking in SQL showed that both orders were cancelled by the same customer 12 and 16 minutes later. If cancellations are only filtered out and not netted against sales, orders like these inflate revenue. So cancelled lines went into `retail_cancellations` (17,894 lines worth 716,232, about 3.6% of gross sales), and `retail_net` combines both tables so that net revenue is sales minus cancellations. Gross revenue is 19,646,349 and net revenue is 18,930,117.

## What the 11 questions cover

Overall size and period, monthly trend, revenue by country, top products, repeat vs one-time customers, top customers, customer segments (RFM-style), cancellations by month, most cancelled products, orders by weekday, and how many new customers come back within 90 days.

## SQL concepts used

CTEs, window functions (ROW_NUMBER, SUM() OVER for shares), CASE WHEN for segments and buckets, UNION ALL and views, LEFT JOIN, DATE_TRUNC and date arithmetic for months, quarters, and recency, EXTRACT for weekdays, REGEXP_REPLACE and TRIM for text cleaning, UPDATE with FROM, and check queries with COUNT and conditional SUM.

Example, a simplified version of Q7, grouping customers into segments by recency and frequency:

```sql
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
    ROUND(SUM(net_revenue), 0) AS net_revenue
FROM rfm
GROUP BY 1
ORDER BY 1;
```

## Key findings

**The business is seasonal, not growing.**
Revenue climbs from September and peaks in November (1.39M in 2010, 1.43M in 2011), about 2.25 times the Jan to Aug average of 2011. It then falls by about 46% in December 2010. Comparing January to November of both years, revenue grew only 2.3%. The weakest months were April and February 2011. The likely reason for the autumn peak is Christmas stocking, but the data does not say.

**Most revenue comes from the UK, but export orders are much bigger.**
The UK brings 85.4% of net revenue. Ireland, Netherlands, Germany, and France are the largest markets after it. The Netherlands placed only 216 orders but averages about 2,528 per order, against about 447 for the UK. Australia (about 1,868) and Ireland (about 1,038) are also well above the UK. These are likely bulk or wholesale buyers, although the data does not label customer type. Among the top 10 countries, Spain was hit hardest by cancellations, with net revenue 13.3% below gross.

**Revenue is spread across products.**
The top 10 products together make only 7.6% of net revenue across 4,733 products. Units sold and revenue tell different stories: the Regency Cakestand sold 25,028 units and leads on revenue, while the Jumbo Bag Red Retrospot sold 95,963 units for much less. After netting cancellations, two products that looked like top sellers dropped out of the top 10, because their huge orders had been cancelled.

**Repeat customers are almost all the revenue.**
72.4% of identified customers bought more than once, and they bring 96.7% of net revenue. One-time buyers are 27.6% of customers but only 3.3% of revenue. This is very different from the marketplace data in my e-commerce project, where only 3% came back, so retention depends a lot on the business model.

**A small group of customers is worth a lot.**
The top 10 customers bring about 16% of identified revenue. Some buy small and often (customer 14911 placed 373 orders at about 693 each) while others buy big and rarely (customer 12415 placed 24 orders at about 5,963 each).

**Customers who have gone quiet are worth winning back.**

| Segment | Customers | % of revenue |
|---|---|---|
| Champions (bought in last 90 days, 5+ orders) | 1,611 | 74.8% |
| Recent customers | 1,274 | 6.2% |
| At risk (3 to 12 months quiet, 5+ orders) | 405 | 7.4% |
| Cooling down | 971 | 4.4% |
| Lost (over a year) | 1,591 | 7.2% |

The "At risk" group is small, but each customer brings about 3,008 on average, roughly four times a Recent, Cooling down, or Lost customer (about 740 to 800). They used to buy often and have gone quiet, so they are the best target for a win-back effort.

**Cancellations are usually small, with a few exceptions.**
In most months 1.2% to 3.8% of gross revenue is cancelled. January 2011 (13.7%) and December 2011 (28.3%) look alarming, but both come from the two large orders mentioned above. Without them, those months fall to about 2.4% and 1.3%. May 2010 (5.8%) and April 2011 (6.5%) are genuinely higher, and the data does not say why.

**Some products are cancelled much more than others.**
Ranked by the share of orders that were later cancelled, the three Cherry Lights products (white, light pink, pink) are on top, with roughly one in three orders affected. Five of the top 10 are lighting products. The data gives no reason, so this only shows where to look.

**The business barely trades on Saturdays.**
Over two years there were only 30 orders on Saturdays. Thursday is the busiest day (20.4% of revenue), followed by Tuesday (19.8%). Sunday is open but light (9.1%).

**New customers come back within 90 days at a rate of 33% to 52%.**
This leaves out the first quarter in the data, which is explained in Limitations. The rate is highest for customers who first bought in July to September (45.0% in 2010, 51.7% in 2011) and lowest for October to December (32.7% in 2010). A likely explanation is that the first group's next 90 days run into the busy autumn season while the second group's run into the quiet winter.

## Limitations

- Revenue is quantity times price. The dataset has no currency, cost, or profit, so nothing here says anything about margin.
- Cancellations are matched to sales by invoice type and product, not by the original order, and a cancellation is counted in the month it happens. Product cancellation ratios are therefore approximate.
- 22.6% of sales rows have no customer ID, so all customer questions cover only identified customers (about 86% of net revenue).
- The 11,491 duplicates outside the overlap window were removed on the assumption that they are repeated entries. If some were genuine separate sales, revenue is understated by a small amount (about 1% of rows).
- Prices are stored with two decimals, so 18 rows priced at 0.001 became 0.00 and were excluded as zero-price lines. The effect is negligible.
- The segment rules (90 and 365 days, 5 orders) are my own thresholds, not a fixed standard.
- December 2011 covers only 9 days. The first cohort in the retention question (Oct to Dec 2009) holds only December, and many of those customers were already buying before the data starts, so they are not truly new.
- The reasons behind the seasonality, the Saturday pattern, and the high-cancellation products are not in the data, so they are described as likely or not explained.

## About me

Palash, data analyst. Skills: SQL, Power BI, Excel, basic Python.
LinkedIn: https://linkedin.com/in/palashadyalkar
