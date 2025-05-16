-- Advanced Item Activity Tool

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET NOCOUNT ON;

DECLARE @Store INT = 7;
DECLARE @StartDate DATETIME = '2025-05-01';
DECLARE @EndDate DATETIME = '2025-05-31';
DECLARE @SearchItem NVARCHAR(50) = '%%';
DECLARE @SearchOrderCode NVARCHAR(50) = '%%';
DECLARE @ActiveItems TABLE (ItemId INT PRIMARY KEY);

INSERT INTO @ActiveItems (ItemId)
SELECT DISTINCT ItemId FROM (
    -- Purchases
    SELECT ii.Item AS ItemId
    FROM oc.InvoiceItem ii
    JOIN oc.Invoice inv ON inv.InvoiceId = ii.Invoice
    WHERE inv.Store = @Store
      AND inv.InvoiceDate BETWEEN @StartDate AND @EndDate

    UNION

    -- Waste
    SELECT iu.Item
    FROM oc.ItemUsage iu
    JOIN oc.UsageSource us ON us.UsageSourceId = iu.UsageSource
    JOIN oc.Waste w ON w.UsageSource = iu.UsageSource
    WHERE us.Store = @Store
      AND us.UsageDate BETWEEN @StartDate AND @EndDate

    UNION

    -- Transfer In
    SELECT iu.Item
    FROM oc.ItemUsage iu
    JOIN oc.UsageSource us ON us.UsageSourceId = iu.UsageSource
    JOIN oc.TransferContext tc ON tc.UsageSource = iu.UsageSource
    JOIN oc.[Transfer] t ON t.Receiver = tc.TransferContextId
    WHERE us.Store = @Store
      AND us.UsageDate BETWEEN @StartDate AND @EndDate

    UNION

    -- Transfer Out
    SELECT iu.Item
    FROM oc.ItemUsage iu
    JOIN oc.UsageSource us ON us.UsageSourceId = iu.UsageSource
    JOIN oc.TransferContext tc ON tc.UsageSource = iu.UsageSource
    JOIN oc.[Transfer] t ON t.Sender = tc.TransferContextId
    WHERE us.Store = @Store
      AND us.UsageDate BETWEEN @StartDate AND @EndDate
) AS Combined



-- Temp table to gather item activity
DECLARE @Activity TABLE (
    ItemId INT,
    ItemDescrip NVARCHAR(100),
    ActivityDate DATETIME,
    ActivityTypeName NVARCHAR(50),
    Amount DECIMAL(11, 3),
    QtyOnHand DECIMAL(11, 3),
    Value DECIMAL(12, 4),
    PurchaseInfo NVARCHAR(100),
    StoreName NVARCHAR(100),
    SupplierName NVARCHAR(100),
    OrderCode NVARCHAR(50),
    CaseCost DECIMAL(12, 4),
    CaseQty DECIMAL(11, 3),
    PakQty DECIMAL(11, 3),
    UnitCost DECIMAL(12, 4),
    PurchaseUom NVARCHAR(10),
    CaseUom NVARCHAR(10),
    PakUom NVARCHAR(10),
    ReportingUom NVARCHAR(10)
);

-- Temp table to hold consistent item info for lookups (used across all activity types)
IF OBJECT_ID('tempdb..#ItemInfo') IS NOT NULL DROP TABLE #ItemInfo;

SELECT DISTINCT
    i.ItemId,
    cs.OrderCode,
    csc.CaseCost,
    cs.CaseQty,
    cs.PakQty,
    iuc.TrackingCost,
    icf.ReportingConversionFactor,
    pu.Uom AS PurchaseUom,
    cu.Uom AS CaseUom,
    pku.Uom AS PakUom,
    ru.Uom AS ReportingUom,
    cat.Name AS CategoryName
INTO #ItemInfo
FROM oc.Item i
JOIN oc.ItemDetail id ON id.Item = i.ItemId
    AND id.Store = @Store
    AND id.TrackInventory = 1
JOIN oc.CaseSize cs ON id.CurrentCaseSize = cs.CaseSizeId
JOIN oc.CaseSizeCost csc ON csc.CaseSize = cs.CaseSizeId
    AND csc.Store = @Store
JOIN oc.ItemUnitCost iuc ON iuc.Item = i.ItemId
    AND iuc.Store = @Store
    AND iuc.Active = 1
JOIN oc.ItemConversionFactor icf ON icf.Item = i.ItemId
JOIN oc.Uom pu ON pu.UomId = cs.PurchaseUom
JOIN oc.Uom cu ON cu.UomId = cs.CaseUom
JOIN oc.Uom pku ON pku.UomId = cs.PakUom
JOIN oc.Uom ru ON ru.UomId = icf.ReportingUom
JOIN oc.[Group] g ON g.GroupId = i.ItemGroup
JOIN oc.Category cat ON cat.CategoryId = g.Category 
WHERE 
    LOWER(cs.OrderCode) LIKE LOWER(@SearchOrderCode) OR @SearchOrderCode = '%%'
;

-- Opening Inventory
INSERT INTO @Activity (
    ItemId, 
    ItemDescrip, 
    ActivityDate, 
    ActivityTypeName,
    Amount, 
    QtyOnHand, 
    Value, 
    PurchaseInfo, 
    StoreName,
    SupplierName, 
    OrderCode, 
    CaseCost, 
    CaseQty, 
    PakQty, 
    UnitCost,
    PurchaseUom, 
    CaseUom, 
    PakUom, 
    ReportingUom    
)
SELECT
    i.ItemId,
    i.Descrip,
    inv.OpenDate,
    'Opening Inventory',
    (invs.QtyOnHand + invs.PreppedQty) / NULLIF(info.ReportingConversionFactor, 0),  -- Amount
    (invs.QtyOnHand + invs.PreppedQty) / NULLIF(info.ReportingConversionFactor, 0),  -- QtyOnHand
    invs.TotalValue,
    '',
    report.RetrieveStoreName(@Store),
    NULL, 
    info.OrderCode,
    info.CaseCost,
    info.CaseQty,
    info.PakQty,
    info.TrackingCost * info.ReportingConversionFactor,
    info.PurchaseUom,
    info.CaseUom,
    info.PakUom,
    info.ReportingUom
FROM oc.Inventory inv
JOIN oc.InventorySummary invs ON inv.InventoryId = invs.Inventory
JOIN oc.Item i ON i.ItemId = invs.Item
JOIN #ItemInfo info ON info.ItemId = i.ItemId
WHERE inv.Store = @Store
  AND inv.Finalized IS NOT NULL
  AND inv.OpenDate BETWEEN @StartDate AND @EndDate
  AND LOWER(i.Descrip) LIKE LOWER(@SearchItem)
  AND i.ItemId IN (SELECT ItemId FROM @ActiveItems);


-- Purchases
INSERT INTO @Activity (
    ItemId, 
    ItemDescrip, 
    ActivityDate, 
    ActivityTypeName,
    Amount, 
    QtyOnHand, 
    Value, 
    PurchaseInfo, 
    StoreName,
    SupplierName, 
    OrderCode, 
    CaseCost, 
    CaseQty, 
    PakQty, 
    UnitCost,
    PurchaseUom, 
    CaseUom, 
    PakUom, 
    ReportingUom    
)
SELECT
    i.ItemId,
    i.Descrip,
    inv.InvoiceDate,
    'Purchase',
    (ii.StockQty - ISNULL(irfc.StockQty, 0)) / NULLIF(info.ReportingConversionFactor, 0), -- Amount
    0,
    ii.AdjustedTotal,
    inv.InvoiceNumber,
    report.RetrieveStoreName(@Store),
    s.Name,
    cs.OrderCode,
    csc.CaseCost,
    cs.CaseQty,
    cs.PakQty,
    iuc.TrackingCost * icf.ReportingConversionFactor,
    pu.Uom, cu.Uom, pku.Uom, ru.Uom
FROM oc.Invoice inv
JOIN oc.InvoiceItem ii ON ii.Invoice = inv.InvoiceId
JOIN oc.Item i ON i.ItemId = ii.Item
LEFT JOIN oc.InvoiceRFC irfc ON ii.InvoiceLineId = irfc.InvoiceItem
JOIN oc.CaseSize cs ON cs.CaseSizeId = ii.CaseSize
JOIN oc.Supplier s ON s.SupplierId = cs.Supplier
JOIN oc.ItemUnitCost iuc ON iuc.Item = i.ItemId AND iuc.Store = @Store AND iuc.Active = 1
JOIN oc.CaseSizeCost csc ON csc.CaseSize = cs.CaseSizeId AND csc.Store = @Store
JOIN oc.ItemConversionFactor icf ON icf.Item = i.ItemId
JOIN oc.Uom pu ON pu.UomId = cs.PurchaseUom
JOIN oc.Uom cu ON cu.UomId = cs.CaseUom
JOIN oc.Uom pku ON pku.UomId = cs.PakUom
JOIN oc.Uom ru ON ru.UomId = icf.ReportingUom
JOIN #ItemInfo info ON info.ItemId = i.ItemId
WHERE inv.Store = @Store
  AND inv.InvoiceDate BETWEEN @StartDate AND @EndDate
  AND LOWER(i.Descrip) LIKE LOWER(@SearchItem)
  AND (cs.OrderCode LIKE @SearchOrderCode OR @SearchOrderCode = '%%')
  AND i.ItemId IN (SELECT ItemId FROM @ActiveItems);



-- Waste
INSERT INTO @Activity (
    ItemId, 
    ItemDescrip, 
    ActivityDate, 
    ActivityTypeName,
    Amount, 
    QtyOnHand, 
    Value, 
    PurchaseInfo, 
    StoreName,
    SupplierName, 
    OrderCode, 
    CaseCost, 
    CaseQty, 
    PakQty, 
    UnitCost,
    PurchaseUom, 
    CaseUom, 
    PakUom, 
    ReportingUom    
)
SELECT
    i.ItemId,
    i.Descrip,
    w.WasteDate,
    'Waste',
    -SUM(iu.StockQty) / NULLIF(info.ReportingConversionFactor, 0),
    0,
    -SUM(iu.TrackingCost * iu.StockQty),
    '',
    report.RetrieveStoreName(@Store),
    NULL, 
    info.OrderCode,
    info.CaseCost,
    info.CaseQty,
    info.PakQty,
    info.TrackingCost * info.ReportingConversionFactor,
    info.PurchaseUom,
    info.CaseUom,
    info.PakUom,
    info.ReportingUom
FROM oc.ItemUsage iu
JOIN oc.UsageSource us ON iu.UsageSource = us.UsageSourceId
JOIN oc.Item i ON i.ItemId = iu.Item
JOIN oc.Waste w ON w.UsageSource = iu.UsageSource
JOIN #ItemInfo info ON info.ItemId = i.ItemId
WHERE us.UsageDate BETWEEN @StartDate AND @EndDate
  AND us.Store = @Store
  AND LOWER(i.Descrip) LIKE LOWER(@SearchItem)
  AND i.ItemId IN (SELECT ItemId FROM @ActiveItems)
GROUP BY 
  i.ItemId, 
  i.Descrip, 
  w.WasteDate,
  info.OrderCode,
  info.CaseCost,
  info.CaseQty,
  info.PakQty,
  info.TrackingCost,
  info.ReportingConversionFactor,
  info.PurchaseUom,
  info.CaseUom,
  info.PakUom,
  info.ReportingUom;

-- Transfer In
INSERT INTO @Activity (
    ItemId, 
    ItemDescrip, 
    ActivityDate, 
    ActivityTypeName,
    Amount, 
    QtyOnHand, 
    Value, 
    PurchaseInfo, 
    StoreName,
    SupplierName, 
    OrderCode, 
    CaseCost, 
    CaseQty, 
    PakQty, 
    UnitCost,
    PurchaseUom, 
    CaseUom, 
    PakUom, 
    ReportingUom    
)
SELECT
    i.ItemId,
    i.Descrip,
    t.TransferDate,
    'Transfer In',
    -SUM(iu.StockQty) / NULLIF(info.ReportingConversionFactor, 0),
    0,
    SUM(iu.StockQty * iu.TrackingCost),
    CAST(t.TransferId AS NVARCHAR(50)),
    report.RetrieveStoreName(@Store),
    s.Identifier,
    info.OrderCode,
    info.CaseCost,
    info.CaseQty,
    info.PakQty,
    info.TrackingCost * info.ReportingConversionFactor,
    info.PurchaseUom,
    info.CaseUom,
    info.PakUom,
    info.ReportingUom
FROM oc.ItemUsage iu
JOIN oc.UsageSource us ON iu.UsageSource = us.UsageSourceId
JOIN oc.Item i ON i.ItemId = iu.Item
JOIN oc.TransferContext tc ON tc.UsageSource = iu.UsageSource
JOIN oc.[Transfer] t ON t.Receiver = tc.TransferContextId
JOIN oc.TransferContext tcs ON tcs.TransferContextId = t.Sender
JOIN oc.Store s ON s.StoreId = tcs.Store
JOIN #ItemInfo info ON info.ItemId = i.ItemId
WHERE us.UsageDate BETWEEN @StartDate AND @EndDate
  AND us.Store = @Store
  AND LOWER(i.Descrip) LIKE LOWER(@SearchItem)
  AND i.ItemId IN (SELECT ItemId FROM @ActiveItems)
GROUP BY 
    i.ItemId, 
    i.Descrip, 
    t.TransferDate,
    t.TransferId,
    s.Identifier, 
    info.OrderCode, 
    info.CaseCost, 
    info.CaseQty, 
    info.PakQty,
    info.TrackingCost, 
    info.ReportingConversionFactor,
    info.PurchaseUom, 
    info.CaseUom, 
    info.PakUom, 
    info.ReportingUom;


-- Transfer Out
INSERT INTO @Activity (
    ItemId, 
    ItemDescrip, 
    ActivityDate, 
    ActivityTypeName,
    Amount, 
    QtyOnHand, 
    Value, 
    PurchaseInfo, 
    StoreName,
    SupplierName, 
    OrderCode, 
    CaseCost, 
    CaseQty, 
    PakQty, 
    UnitCost,
    PurchaseUom, 
    CaseUom, 
    PakUom, 
    ReportingUom    
)
SELECT
    i.ItemId,
    i.Descrip,
    t.TransferDate,
    'Transfer Out',
    -SUM(iu.StockQty) / NULLIF(info.ReportingConversionFactor, 0),
    0,
    -SUM(iu.StockQty * iu.TrackingCost),
    CAST(t.TransferId AS NVARCHAR(50)),
    report.RetrieveStoreName(@Store),
    s.Identifier,
      info.OrderCode,
    info.CaseCost,
    info.CaseQty,
    info.PakQty,
    info.TrackingCost * info.ReportingConversionFactor,
    info.PurchaseUom,
    info.CaseUom,
    info.PakUom,
    info.ReportingUom
FROM oc.ItemUsage iu
JOIN oc.UsageSource us ON iu.UsageSource = us.UsageSourceId
JOIN oc.Item i ON i.ItemId = iu.Item
JOIN oc.TransferContext tc ON tc.UsageSource = iu.UsageSource
JOIN oc.[Transfer] t ON t.Sender = tc.TransferContextId
JOIN oc.TransferContext tcr ON tcr.TransferContextId = t.Receiver
JOIN oc.Store s ON s.StoreId = tcr.Store
JOIN #ItemInfo info ON info.ItemId = i.ItemId
WHERE us.UsageDate BETWEEN @StartDate AND @EndDate
  AND us.Store = @Store
  AND LOWER(i.Descrip) LIKE LOWER(@SearchItem)
  AND i.ItemId IN (SELECT ItemId FROM @ActiveItems)
GROUP BY 
    i.ItemId, 
    i.Descrip, 
    t.TransferDate,
    t.TransferId,
    s.Identifier,
    info.OrderCode, 
    info.CaseCost, 
    info.CaseQty, 
    info.PakQty,
    info.TrackingCost, 
    info.ReportingConversionFactor,
    info.PurchaseUom, 
    info.CaseUom, 
    info.PakUom, 
    info.ReportingUom;;


-- Ending Inventory
INSERT INTO @Activity (
    ItemId, 
    ItemDescrip, 
    ActivityDate, 
    ActivityTypeName,
    Amount, 
    QtyOnHand, 
    Value, 
    PurchaseInfo, 
    StoreName,
    SupplierName, 
    OrderCode, 
    CaseCost, 
    CaseQty, 
    PakQty, 
    UnitCost,
    PurchaseUom, 
    CaseUom, 
    PakUom, 
    ReportingUom    
)
SELECT
    i.ItemId,
    i.Descrip,
    inv.CloseDate,
    'Ending Inventory',
    (invsum.QtyOnHand + invsum.PreppedQty) / NULLIF(info.ReportingConversionFactor, 0),
    (invsum.QtyOnHand + invsum.PreppedQty) / NULLIF(info.ReportingConversionFactor, 0),
    invsum.TotalValue,
    '',
    report.RetrieveStoreName(@Store),
    NULL, 
    info.OrderCode,
    info.CaseCost,
    info.CaseQty,
    info.PakQty,
    info.TrackingCost * info.ReportingConversionFactor,
    info.PurchaseUom,
    info.CaseUom,
    info.PakUom,
    info.ReportingUom
FROM oc.Inventory inv
JOIN oc.InventorySummary invsum ON inv.InventoryId = invsum.Inventory
JOIN oc.Item i ON i.ItemId = invsum.Item
JOIN #ItemInfo info ON info.ItemId = i.ItemId
WHERE inv.Store = @Store
  AND inv.CloseDate BETWEEN @StartDate AND @EndDate
  AND inv.Finalized IS NOT NULL
  AND LOWER(i.Descrip) LIKE LOWER(@SearchItem)
  AND i.ItemId IN (SELECT ItemId FROM @ActiveItems);

-- Optional: Aggregate value per item (Subtotal)
-- You can uncomment if you want a summarized row per item
/*
INSERT INTO @Activity
SELECT
    ItemId,
    MAX(ItemDescrip),
    NULL,
    'Subtotal',
    SUM(Amount),
    NULL,
    SUM(Value),
    '',
    MAX(StoreName),
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
FROM @Activity
GROUP BY ItemId
*/

-- Optional: Calculate Unit Cost via ReportingUOM
-- If needed, you can use this format:
-- UnitCost = CASE WHEN Qty <> 0 THEN Value / Qty ELSE NULL END

-- Final Output
SELECT 
    a.ItemDescrip As "Item",
    info.CategoryName AS "Category", 
    -- a.ItemId,
    CONVERT(DATE, ActivityDate) AS "Date",
    a.ActivityTypeName AS "Activity Type",    
    a.SupplierName AS "Vendor/Store",
    a.Amount AS "Qty", --As Reporting UoM
    a.ReportingUom AS "Reporting_UoM",    
    --a.CaseQty,
    --a.PakQty,
    --a.PurchaseUom,
    --a.CaseUom,
    --a.PakUom,
    --a.QtyOnHand,
    a.Value AS "Activity Value $",    
    a.CaseCost,
    a.UnitCost AS "UoM Cost",
    a.PurchaseInfo AS "Ref/Inv #",
    a.OrderCode AS "Vendor Code",
    a.StoreName

FROM @Activity a
JOIN #ItemInfo info ON info.ItemId = a.ItemId
ORDER BY 
  ItemDescrip, 
  CONVERT(DATE, ActivityDate),
  CASE ActivityTypeName
      WHEN 'Opening Inventory' THEN 1
      WHEN 'Transfer In' THEN 2
      WHEN 'Transfer Out' THEN 3
      WHEN 'Purchase' THEN 4
      WHEN 'Waste' THEN 5
      WHEN 'Ending Inventory' THEN 6
      ELSE 99 -- Any unexpected or future activity types go to the end
    END;
