-- Core query for item inventory details with Supplier and OrderCode columns, including filters for ItemDescrip and OrderCode
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET NOCOUNT ON;

-- Store ID Values
  -- 1	Store #1
  -- 2	Store #2
  -- 3	Store #3
  -- 4	Store #4

-- Define variables to simulate parameter inputs (replace with actual values or input parameters as needed)
DECLARE @Store SMALLINT = NULL;                        -- Set to NULL for all stores, or specify a specific Store ID
DECLARE @SearchItem NVARCHAR(50) =    '%%';          -- Input for Item Description search term; use '%' for wildcard matching
DECLARE @SearchOrderCode NVARCHAR(50) = '%%';     -- Input for Order Code search term; use '%' for wildcard matching

-- Core query selecting item inventory details
SELECT 
    StoreName = report.RetrieveStoreName(ISNULL(@Store, ItemDetail.Store)),  -- Store name; displays based on @Store value or NULL for all stores
    -- Category.CategoryId,                     -- Category ID for Category Name
    Category.Name AS CategoryName,
    -- [Group].GroupId,                         -- Group ID value for Group Description
    -- [Group].Descrip AS GroupDescrip,         -- Group Description
    Item.ItemId,                                -- OC Item ID value. Used too check item duplication.
    Item.Descrip AS ItemDescrip,                -- Item Description as entered in OC
    si.SupplierName,                            -- Supplier Name
    si.OrderCode,                               -- Supplier Order Code
    CaseSizeCost.CaseCost,                      -- Dollar value of Case Cost
    CaseSize.CaseQty,
    CaseSize.PakQty,
    UnitCost = ItemUnitCost.TrackingCost * icf.ReportingConversionFactor,
    PurchaseUom.Uom AS PurchaseUom,
    CaseUom.Uom AS CaseUom,
    PakUom.Uom AS PakUom,
    QtyOnHand = ItemQtyOnHand.QtyOnHand / icf.ReportingConversionFactor,
    ApproxValue = CAST(ItemQtyOnHand.QtyOnHand * ItemUnitCost.TrackingCost AS DECIMAL(13,2)),
    ilr.LastReceived,
    ReportingUom.Uom AS ReportingUom
FROM 
    oc.Item
    -- Join with ItemDetail for store-specific item details
    JOIN oc.ItemDetail ON ItemDetail.Item = Item.ItemId
        AND (ItemDetail.Store = @Store OR @Store IS NULL)  -- Filter by store, or include all if @Store is NULL
        AND ItemDetail.TrackInventory = 1
    -- Join with CaseSize for packaging details
    JOIN oc.CaseSize ON ItemDetail.CurrentCaseSize = CaseSize.CaseSizeId
    -- Join with CaseSizeCost for cost details
    JOIN oc.CaseSizeCost ON CaseSizeCost.CaseSize = CaseSize.CaseSizeId
        AND CaseSizeCost.Store = ItemDetail.Store
    -- Join with ItemUnitCost for cost-per-unit information
    JOIN oc.ItemUnitCost ON ItemUnitCost.Item = Item.ItemId
        AND ItemUnitCost.Store = ItemDetail.Store
        AND ItemUnitCost.Active = 1
    -- Join with ItemQtyOnHand for quantity on hand details
    JOIN oc.ItemQtyOnHand ON ItemQtyOnHand.Item = Item.ItemId
        AND ItemQtyOnHand.Store = ItemDetail.Store
    -- Join with Uom for various unit of measure descriptions
    JOIN oc.Uom AS PurchaseUom ON PurchaseUom.UomId = CaseSize.PurchaseUom
    JOIN oc.Uom AS PakUom ON PakUom.UomId = CaseSize.PakUom
    JOIN oc.Uom AS CaseUom ON CaseUom.UomId = CaseSize.CaseUom
    -- Join with Group and Category tables for item grouping and categorization
    JOIN oc.[Group] ON [Group].GroupId = Item.ItemGroup
    JOIN oc.Category ON Category.CategoryId = [Group].Category
    -- Join with ItemConversionFactor and ReportingUom for reporting conversions
    JOIN oc.ItemConversionFactor AS icf ON icf.Item = Item.ItemId
    JOIN oc.Uom AS ReportingUom ON ReportingUom.UomId = icf.ReportingUom
    -- Join with ItemLastReceived for the last received date
    JOIN oc.ItemLastReceived AS ilr ON ilr.Item = Item.ItemId
        AND (ilr.Store = @Store OR @Store IS NULL)
    -- Supplier Information: Most recent Supplier and OrderCode from CaseSize
    LEFT JOIN (
        SELECT
            cs.Item,                                 -- Item ID from CaseSize
            s.Name AS SupplierName,                  -- Supplier Name from oc.Supplier table
            cs.OrderCode,                            -- Supplier's Order code from oc.CaseSize table
            ROW_NUMBER() OVER (PARTITION BY cs.Item ORDER BY i.InvoiceDate DESC) AS rn  -- Ranking to get the most recent supplier/order code
        FROM oc.CaseSize cs
        JOIN oc.InvoiceItem ii ON ii.Item = cs.Item  -- Join InvoiceItem to tie invoices to items
        JOIN oc.Invoice i ON i.InvoiceId = ii.Invoice  -- Join Invoice table to get InvoiceDate and Supplier
        JOIN oc.Supplier s ON s.SupplierId = i.Supplier  -- Join Supplier to fetch supplier name
        WHERE ISNUMERIC(LEFT(s.Name, 1)) = 0  -- Exclude internal suppliers whose names start with a number
    ) si ON si.Item = Item.ItemId AND si.rn = 1  -- Only get the most recent record per item
WHERE
    -- Filter by Item Description if specified; allows partial matching with wildcards
    (@SearchItem IS NULL OR LOWER(Item.Descrip) LIKE LOWER('%' + @SearchItem + '%'))
    -- Filter by Order Code if specified; allows partial matching with wildcards
    AND (@SearchOrderCode IS NULL OR si.OrderCode LIKE '%' + @SearchOrderCode + '%');

-- Reset transaction isolation level and re-enable row count output
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SET NOCOUNT OFF;
