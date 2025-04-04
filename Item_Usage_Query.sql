-- Query in progress 9/18/24
-- TracRite>Optimum Control Inventory Measurement Tool
-- Output:
    -- Item Description, Internal Item ID, Recent Supplier, 
    -- Supplier Order Code, Inv. Category Name, Item Storage 
    -- Location, Reporting UOM, Opening Inv, Purchase Qty, 
    -- X-Fer In Qty, X-Fer Out Qty, Waste Qty, Ending Inv Qty, 
    -- Usage Qty. Purchase Value, End Inv. Value

-- Store ID Values
  -- 1	Store #1
  -- 2	Store #2
  -- 3	Store #3
  
-- Set transaction isolation level and prevent extra result sets
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET NOCOUNT ON;                             -- Disable extra messages about affected rows to keep output clean.

-- Declare variables to filter the data
DECLARE @Store SMALLINT = 2;                -- Store ID smallint
DECLARE @StartDate DATETIME = '2025-03-01'; -- Start date for the reporting period
DECLARE @EndDate DATETIME = '2025-03-31';   -- End date for the reporting period

-- Declare a temporary table to hold the summary data
DECLARE @UsageSummary TABLE (
    ItemId SMALLINT,              -- Item ID from Optimum Control
    ItemDescrip NVARCHAR(50),      -- Item Description
    Supplier NVARCHAR(100),        -- Supplier Name
    OrderCode NVARCHAR(50),        -- Order Code
    Category_Name NVARCHAR(50),    -- Category Name
    Item_Location NVARCHAR(50),    -- Primary Location Name
    UOM NVARCHAR(17),              -- Unit of Measure
    OpenInvQty DECIMAL(14, 3),     -- Opening Inventory Quantity
    PurchaseQty DECIMAL(14, 3),    -- Period Purchase Quantity
    TransferOutQty DECIMAL(14, 3), -- Transfer Out Quantity
    TransferInQty DECIMAL(14, 3),  -- Transfer In Quantity
    WasteQty DECIMAL(14, 3),       -- Waste Quantity
    EndInvQty DECIMAL(14, 3),      -- Ending Inventory Quantity
    UsageQty DECIMAL(14, 3),       -- Actual Usage Quantity
    ApproxValue DECIMAL(15, 4),    -- Approximate Value (calculated using average cost)
    EndInvValue DECIMAL(15, 4)     -- Ending Inventory Value
);

-- Insert data into the temporary table from various inventory and item-related tables
INSERT INTO @UsageSummary
SELECT 
    i.ItemId,                     --Internal Item ID
    i.Descrip AS ItemDescrip,       --Item Description from oc.Item table
    si.SupplierName,                --Most recent Supplier from subquery
    si.OrderCode,                   --Most Recent OrderCode from subquery
    c.Name AS Category_Name,        --Item Category from oc.Category table
    l.Name AS Item_Location,        --Item primary location from oc.Location table
    u.Descrip AS UOM,               --Unit of Measure or UOM
    -- Opening Inventory (calculated using conversion factor)
    COALESCE(insu_open.QtyOnHand, 0) / icf.ReportingConversionFactor 
    + COALESCE(insu_open.PreppedQty, 0) / icf.ReportingConversionFactor AS OpenInvQty,
    -- Purchases durring the period (adjusted for conversion to Reporting Units)
    COALESCE(ui.InvoiceSum, 0) / icf.ReportingConversionFactor AS PurchaseQty,
    -- Transfers Out durring the period
    COALESCE(tout.TransferOutQty, 0) / icf.ReportingConversionFactor AS TransferOutQty,
    -- Transfers In durring the period
    COALESCE(tin.TransferInQty, 0) / icf.ReportingConversionFactor AS TransferInQty,
    -- Waste durring the period
    COALESCE(waste.WasteQty, 0) / icf.ReportingConversionFactor AS WasteQty,
    -- Ending Inventory (calculated using the conversion factor)
    COALESCE(insu_close.QtyOnHand, 0) / icf.ReportingConversionFactor 
    + COALESCE(insu_close.PreppedQty, 0) / icf.ReportingConversionFactor AS EndInvQty,
    -- Usage is calculated as the sum of all inventory transactions minus ending inventory
    (COALESCE(insu_open.QtyOnHand, 0) / icf.ReportingConversionFactor 
    + COALESCE(insu_open.PreppedQty, 0) / icf.ReportingConversionFactor 
    + COALESCE(ui.InvoiceSum, 0) / icf.ReportingConversionFactor 
    + COALESCE(tout.TransferOutQty, 0) / icf.ReportingConversionFactor 
    + COALESCE(tin.TransferInQty, 0) / icf.ReportingConversionFactor 
    + COALESCE(waste.WasteQty, 0) / icf.ReportingConversionFactor) 
    - (COALESCE(insu_close.QtyOnHand, 0) / icf.ReportingConversionFactor 
    + COALESCE(insu_close.PreppedQty, 0) / icf.ReportingConversionFactor) AS UsageQty,
    -- Approximate value change based on purchases and inventory changes
    (COALESCE(insu_open.TotalValue, 0) + COALESCE(ui.InvoiceValue, 0) 
    - COALESCE(insu_close.TotalValue, 0)) AS ApproxValue,
    -- Ending inventory value
    COALESCE(insu_close.TotalValue, 0) AS EndInvValue
FROM 
    oc.Item i
    -- Join with Category table to fetch Category Name
    LEFT JOIN oc.[Group] g ON g.GroupId = i.ItemGroup
    LEFT JOIN oc.Category c ON c.CategoryId = g.Category 
    -- Join with KeyItemDetail table to fetch Primary Location based on the Store
    LEFT JOIN oc.KeyItemDetail kid ON kid.Item = i.ItemId AND kid.Store = @Store
    LEFT JOIN oc.Location l ON l.LocationId = kid.PrimaryLocation


-- Supplier Information: Get the most recent OrderCode and Supplier for each item from CaseSize
LEFT JOIN (
    SELECT
        cs.Item,                                 -- Item ID from CaseSize
        s.Name AS SupplierName,                  -- Supplier Name from oc.Supplier table
        cs.OrderCode,                            -- Order code from oc.CaseSize table
        ROW_NUMBER() OVER (PARTITION BY cs.Item ORDER BY i.InvoiceDate DESC) AS rn  -- Ranking to get the most recent supplier/order code
    FROM oc.CaseSize cs
    JOIN oc.InvoiceItem ii ON ii.Item = cs.Item  -- Joining InvoiceItem to tie invoices to items
    JOIN oc.Invoice i ON i.InvoiceId = ii.Invoice  -- Joining Invoice table to get InvoiceDate and Supplier
    JOIN oc.Supplier s ON s.SupplierId = i.Supplier  -- Joining Supplier to fetch supplier name based on SupplierId from Invoice
    WHERE ISNUMERIC(LEFT(s.Name, 1)) = 0  -- Exclude internal suppliers whose names start with a number
) si ON si.Item = i.ItemId AND si.rn = 1  -- Only get the most recent record per item


    -- Join with Inventory Summary for Opening Inventory
    LEFT JOIN oc.Inventory inv_open ON inv_open.OpenDate = @StartDate AND inv_open.Store = @Store
    LEFT JOIN oc.InventorySummary insu_open ON inv_open.InventoryId = insu_open.Inventory 
    AND insu_open.Item = i.ItemId

    -- Join with Inventory Summary for Closing Inventory
    LEFT JOIN oc.Inventory inv_close ON inv_close.CloseDate = @EndDate AND inv_close.Store = @Store
    LEFT JOIN oc.InventorySummary insu_close ON inv_close.InventoryId = insu_close.Inventory 
    AND insu_close.Item = i.ItemId


    -- Join with Invoice data for Period Purchases
    LEFT JOIN (
        SELECT 
            ii.Item,
            i.Store,
            SUM(ii.StockQty - COALESCE(ir.StockQty, 0)) AS InvoiceSum,
            SUM(ii.AdjustedTotal) AS InvoiceValue
        FROM 
            oc.InvoiceItem ii
            JOIN oc.Invoice i ON i.InvoiceId = ii.Invoice 
            AND i.InvoiceDate BETWEEN @StartDate AND @EndDate
            LEFT JOIN oc.InvoiceRFC ir ON ii.InvoiceLineId = ir.InvoiceItem
        WHERE i.Store = @Store
        GROUP BY ii.Item, i.Store
    ) AS ui ON ui.Item = i.ItemId


    -- Transfer Out Data
    LEFT JOIN (
        SELECT 
            iu.Item, 
            SUM(-iu.StockQty) AS TransferOutQty
        FROM oc.ItemUsage iu
        JOIN oc.TransferContext tc ON tc.UsageSource = iu.UsageSource
        JOIN oc.[Transfer] t ON t.Sender = tc.TransferContextId
        WHERE t.TransferDate BETWEEN @StartDate AND @EndDate AND tc.Store = @Store
        GROUP BY iu.Item
    ) AS tout ON tout.Item = i.ItemId


    -- Transfer In Data
    LEFT JOIN (
        SELECT 
            iu.Item, 
            SUM(-iu.StockQty) AS TransferInQty
        FROM oc.ItemUsage iu
        JOIN oc.TransferContext tc ON tc.UsageSource = iu.UsageSource
        JOIN oc.[Transfer] t ON t.Receiver = tc.TransferContextId
        WHERE t.TransferDate BETWEEN @StartDate AND @EndDate AND tc.Store = @Store
        GROUP BY iu.Item
    ) AS tin ON tin.Item = i.ItemId


    -- Waste Data
    LEFT JOIN (
        SELECT 
            iu.Item, 
            SUM(-iu.StockQty) AS WasteQty
        FROM oc.ItemUsage iu
        JOIN oc.UsageSource us ON iu.UsageSource = us.UsageSourceId
        JOIN oc.Waste w ON w.UsageSource = iu.UsageSource
        WHERE w.WasteDate BETWEEN @StartDate AND @EndDate AND us.Store = @Store
        GROUP BY iu.Item
    ) AS waste ON waste.Item = i.ItemId

    -- Join with Unit of Measure to fetch correct UOM for reporting
    LEFT JOIN oc.ItemConversionFactor icf ON icf.Item = i.ItemId
    LEFT JOIN oc.Uom u ON u.UomId = icf.ReportingUom;


-- Final selection from the temporary table with data filters and sorting
SELECT 
    -- ItemId AS OC_ItemID,        -- Internal OC Item ID
    ItemDescrip,                -- Item Description - user entered
    Supplier,                   -- Supplier Name
    OrderCode,                  -- Supplier's Order Code
    Category_Name,              -- Inventory Category Name
    Item_Location,              -- Item Storage Location
    UOM,                        -- Reporting Unit of Measure
    OpenInvQty,                 -- Opening Inventory for the period
    PurchaseQty,                -- Quantity Purchased
    TransferOutQty,             -- Quantity Transfered OUT
    TransferInQty,              -- Quantity Transfered IN
    WasteQty,                   -- Quantity Wasted
    EndInvQty,                  -- Ending Inventory as entered at the end of a period, if entered
    UsageQty                   -- Usage calculated by the difference between opeing + action minus ending inventory
    -- ApproxValue AS Ave_Cost,    -- Average Cost
    -- EndInvValue AS End_Inv_Value -- Ending Inventory Value
FROM @UsageSummary
-- Filter out rows with no meaningful transaction data (aka rows where no data is recorded)
WHERE 
    (OpenInvQty <> 0 OR PurchaseQty <> 0 OR TransferOutQty <> 0 OR 
     TransferInQty <> 0 OR WasteQty <> 0 OR EndInvQty <> 0)
-- Order by Category name and then Item Description for clairity in repots    
ORDER BY 
    Category_Name, 
    Item_Location,
    ItemDescrip;


-- Reset transaction isolation level and re-enable row count output
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SET NOCOUNT OFF;
