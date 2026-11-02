/* =========================================================================
   E-COMMERCE DATASET — SQL SOLUTIONS (Q14 to Q20)
   Tables used:
     Orders(OrderDate, OrderID, [Delivery Date], CustomerID, Location, Zone,
            [Delivery Type], [Product Category], SubCategory, Product,
            [Unit Price], [Shipping Fee], [Order Quantity], [Sale Price],
            Status, Reason, Rating)
     Customers(CustomerID, [Customer Age], [Customer Gender])

   ========================================================================= */


-- =========================================================================
-- Q14: Top 5 most valuable customers using a composite score
--      Total Revenue (50%) + Order Frequency (30%) + Avg Order Value (20%)
--      Each metric is min-max normalized to 0-1 first, so no single metric
--      (e.g. Revenue, which is on a much bigger scale) dominates the score.
-- =========================================================================
WITH CustomerMetrics AS (
    SELECT
        CustomerID,
        SUM([Sale Price])              AS Total_Revenue,
        COUNT(OrderID)                 AS Order_Frequency,
        COALESCE(AVG([Sale Price]), 0) AS Avg_Order_Value
    FROM Orders
    GROUP BY CustomerID
),
NormalizedMetrics AS (
    SELECT
        CustomerID,
        Total_Revenue,
        Order_Frequency,
        Avg_Order_Value,
        (Total_Revenue - MIN(Total_Revenue) OVER())
            / NULLIF(MAX(Total_Revenue) OVER() - MIN(Total_Revenue) OVER(), 0) AS Norm_Revenue,
        (Order_Frequency - MIN(Order_Frequency) OVER())
            / NULLIF(MAX(Order_Frequency) OVER() - MIN(Order_Frequency) OVER(), 0) AS Norm_Frequency,
        (Avg_Order_Value - MIN(Avg_Order_Value) OVER())
            / NULLIF(MAX(Avg_Order_Value) OVER() - MIN(Avg_Order_Value) OVER(), 0) AS Norm_AOV
    FROM CustomerMetrics
)
SELECT TOP 5
    CustomerID,
    Total_Revenue,
    Order_Frequency,
    Avg_Order_Value,
    ROUND(0.5 * Norm_Revenue + 0.3 * Norm_Frequency + 0.2 * Norm_AOV, 4) AS Composite_Score
FROM NormalizedMetrics
ORDER BY Composite_Score DESC;


-- =========================================================================
-- Q15: Month-over-month growth rate in total revenue across the entire
--      dataset.
--      (Written without LAG(), since this server is SQL Server 2008 R2,
--       and LAG/LEAD only exist from SQL Server 2012 onward. Instead, a
--       MonthIndex = Year*12+Month lets us self-join each month to the
--       one immediately before it.)
-- =========================================================================
WITH MonthlyRevenue AS (
    SELECT
        YEAR(OrderDate)                          AS OrderYear,
        MONTH(OrderDate)                         AS OrderMonth,
        (YEAR(OrderDate) * 12 + MONTH(OrderDate)) AS MonthIndex,
        SUM([Sale Price])                        AS Total_Revenue
    FROM Orders
    WHERE OrderDate IS NOT NULL   -- excludes 199 orders with missing dates
    GROUP BY YEAR(OrderDate), MONTH(OrderDate)
)
SELECT
    cur.OrderYear,
    cur.OrderMonth,
    cur.Total_Revenue,
    prev.Total_Revenue AS Prev_Month_Revenue,
    CASE
        WHEN prev.Total_Revenue IS NULL OR prev.Total_Revenue = 0 THEN NULL
        ELSE ROUND((cur.Total_Revenue - prev.Total_Revenue) / prev.Total_Revenue * 100, 2)
    END AS MoM_Growth_Rate_Percent
FROM MonthlyRevenue cur
LEFT JOIN MonthlyRevenue prev
    ON prev.MonthIndex = cur.MonthIndex - 1
ORDER BY cur.OrderYear, cur.OrderMonth;


-- =========================================================================
-- Q16: Rolling 3-month average revenue for each product category.
--      (Written without "ROWS BETWEEN ... PRECEDING" framing, since that
--       window-frame syntax only exists from SQL Server 2012 onward. This
--       server is SQL Server 2008 R2. Instead, each month is self-joined
--       to itself and the 2 months before it, then averaged with GROUP BY.)
-- =========================================================================
WITH MonthlyCategoryRevenue AS (
    SELECT
        [Product Category]                        AS ProductCategory,
        YEAR(OrderDate)                            AS OrderYear,
        MONTH(OrderDate)                           AS OrderMonth,
        (YEAR(OrderDate) * 12 + MONTH(OrderDate))  AS MonthIndex,
        SUM([Sale Price])                          AS Monthly_Revenue
    FROM Orders
    WHERE OrderDate IS NOT NULL   -- excludes 199 orders with missing dates
    GROUP BY [Product Category], YEAR(OrderDate), MONTH(OrderDate)
)
SELECT
    cur.ProductCategory,
    cur.OrderYear,
    cur.OrderMonth,
    cur.Monthly_Revenue,
    ROUND(AVG(win.Monthly_Revenue), 2) AS Rolling_3Month_Avg_Revenue
FROM MonthlyCategoryRevenue cur
JOIN MonthlyCategoryRevenue win
    ON win.ProductCategory = cur.ProductCategory
   AND win.MonthIndex BETWEEN cur.MonthIndex - 2 AND cur.MonthIndex
GROUP BY cur.ProductCategory, cur.OrderYear, cur.OrderMonth, cur.Monthly_Revenue
ORDER BY cur.ProductCategory, cur.OrderYear, cur.OrderMonth;


-- =========================================================================
-- Q17: Apply a 15% discount on Sale Price for orders placed by customers
--      who have made at least 10 orders.
--      *** This is a data-modifying UPDATE — back up the table first. ***
-- =========================================================================
UPDATE Orders
SET [Sale Price] = ROUND([Sale Price] * 0.85, 2)
WHERE CustomerID IN (
    SELECT CustomerID
    FROM Orders
    WHERE CustomerID IS NOT NULL
      AND OrderID IS NOT NULL
    GROUP BY CustomerID
    HAVING COUNT(DISTINCT OrderID) >= 10
);
-- =========================================================================
-- Q18: Average number of days between consecutive orders, for customers
--      who have placed at least five orders. (One row per qualifying
--      customer, showing their personal average gap between orders.)
--      (Written without LAG(), since this server is SQL Server 2008 R2.
--       ROW_NUMBER() IS supported since SQL Server 2005, so we number
--       each customer's orders by date, then self-join row N to row N-1
--       to get the previous order date.)
-- =========================================================================
WITH OrderedOrders AS (
    SELECT
        CustomerID,
        OrderDate,
        ROW_NUMBER() OVER (PARTITION BY CustomerID ORDER BY OrderDate, OrderID) AS rn
    FROM Orders
),
OrderGaps AS (
    SELECT
        cur.CustomerID,
        DATEDIFF(DAY, prev.OrderDate, cur.OrderDate) AS Days_Since_Last_Order
    FROM OrderedOrders cur
    JOIN OrderedOrders prev
        ON cur.CustomerID = prev.CustomerID
       AND cur.rn = prev.rn + 1
),
QualifyingCustomers AS (
    SELECT CustomerID
    FROM Orders
    GROUP BY CustomerID
    HAVING COUNT(OrderID) >= 5
)
SELECT
    g.CustomerID,
    ROUND(AVG(g.Days_Since_Last_Order * 1.0), 2) AS Avg_Days_Between_Orders
FROM OrderGaps g
JOIN QualifyingCustomers q ON g.CustomerID = q.CustomerID
GROUP BY g.CustomerID
ORDER BY g.CustomerID;

-- If you instead want ONE overall number (across all qualifying customers
-- combined), wrap the query above as a subquery and take a single AVG():
-- SELECT ROUND(AVG(Avg_Days_Between_Orders), 2) AS Overall_Avg_Days_Between_Orders
-- FROM ( ...query above... ) AS PerCustomer;


-- =========================================================================
-- Q19: Customers who have generated revenue more than 30% higher than the
--      average revenue per customer.
-- =========================================================================
WITH CustomerRevenue AS (
    SELECT
        CustomerID,
        SUM([Sale Price]) AS Total_Revenue
    FROM Orders
    GROUP BY CustomerID
),
AvgRevenue AS (
    SELECT AVG(Total_Revenue) AS Avg_Customer_Revenue
    FROM CustomerRevenue
)
SELECT
    cr.CustomerID,
    cr.Total_Revenue,
    ar.Avg_Customer_Revenue,
    ROUND(((cr.Total_Revenue - ar.Avg_Customer_Revenue) / ar.Avg_Customer_Revenue) * 100, 2) AS Pct_Above_Average
FROM CustomerRevenue cr
CROSS JOIN AvgRevenue ar
WHERE cr.Total_Revenue > ar.Avg_Customer_Revenue * 1.3
ORDER BY cr.Total_Revenue DESC;


-- =========================================================================
-- Q20: Top 3 product categories with the highest increase in sales over
--      the past year compared to the previous year.
--      (Automatically uses the latest year present in the data vs. the
--      year before it — no need to hardcode a year.)
-- =========================================================================
WITH YearlyCategoryRevenue AS (
    SELECT
        [Product Category] AS ProductCategory,
        YEAR(OrderDate)     AS OrderYear,
        SUM([Sale Price])   AS Yearly_Revenue
    FROM Orders
    GROUP BY [Product Category], YEAR(OrderDate)
),
LatestYear AS (
    SELECT MAX(OrderYear) AS MaxYear FROM YearlyCategoryRevenue
),
YoYComparison AS (
    SELECT
        cur.ProductCategory,
        prev.Yearly_Revenue AS Previous_Year_Revenue,
        cur.Yearly_Revenue  AS Current_Year_Revenue,
        cur.Yearly_Revenue - COALESCE(prev.Yearly_Revenue, 0) AS Revenue_Increase
    FROM YearlyCategoryRevenue cur
    CROSS JOIN LatestYear ly
    LEFT JOIN YearlyCategoryRevenue prev
        ON cur.ProductCategory = prev.ProductCategory
       AND prev.OrderYear = cur.OrderYear - 1
    WHERE cur.OrderYear = ly.MaxYear
)
SELECT TOP 3
    ProductCategory,
    Previous_Year_Revenue,
    Current_Year_Revenue,
    Revenue_Increase
FROM YoYComparison
ORDER BY Revenue_Increase DESC;
