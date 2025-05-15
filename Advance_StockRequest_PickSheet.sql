--Advance Stock Request Pick Sheet.
--Highlights disconnects between Item Uom vs amount requested --saving inventory issues.
--shows vendor Order Codes for use when ordering product
--Also shows title of req, notes, dates, and employee login of user who placed order.
--Filtered to only show "Unfulfilled" orders (Pending or Approved) for the last 30 days. 

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET NOCOUNT ON;

DECLARE @Store INT = 2;

-- CTE: Get the latest status for each Requisition
WITH LatestRequisitionStatus AS (
    SELECT rs.Requisition, rs.Status, rs.EffectiveDate, rs.Employee
    FROM oc.RequisitionStatus rs
    WHERE rs.EffectiveDate = (
        SELECT MAX(rs2.EffectiveDate)
        FROM oc.RequisitionStatus rs2
        WHERE rs2.Requisition = rs.Requisition
    )
),

-- CTE: Get the latest line-level status per RequisitionItem
LatestItemStatus AS (
    SELECT ris.RequisitionItem, ris.Qty, ris.Uom, ris.RequisitionStatus
    FROM oc.RequisitionItemStatus ris
    WHERE ris.RequisitionStatus IN (
        SELECT MAX(ris2.RequisitionStatus)
        FROM oc.RequisitionItemStatus ris2
        WHERE ris2.RequisitionItem = ris.RequisitionItem
    )
)

SELECT 
    i.Descrip AS ItemName,    
    lis.Qty AS QtyRequested,
    u_req.Uom AS RequestUom,
    u.Uom AS ReportingUom,
    CASE 
        WHEN u_req.Uom <> u.Uom THEN '⚠️MISMATCH⚠️' 
        ELSE 'OK' 
    END AS UomMismatchFlag,    
    c.Name AS CategoryName,
    sending.Name AS Sender,
    receiving.Name AS Receiver,    
    s.Name AS Supplier,
    cs.OrderCode,
    r.Description AS StockReq_Descrip,
    r.Notes AS StockReq_Notes,
    r.DateRequired,
    lrs.EffectiveDate,   
    sending.Name AS StoreName,
    emp.FirstName AS Employee

FROM oc.Requisition r
JOIN LatestRequisitionStatus lrs ON lrs.Requisition = r.RequisitionId
JOIN oc.Store sending ON sending.StoreId = r.SendingStore
JOIN oc.Store receiving ON receiving.StoreId = r.ReceivingStore
JOIN security.Employee emp ON emp.EmployeeId = lrs.Employee
JOIN oc.RequisitionItem ri ON ri.Requisition = r.RequisitionId
JOIN LatestItemStatus lis ON lis.RequisitionItem = ri.RequisitionItemId
JOIN oc.Item i ON i.ItemId = ri.Item
JOIN oc.[Group] g ON g.GroupId = i.ItemGroup
JOIN oc.Category c ON c.CategoryId = g.Category
JOIN oc.ItemDetail id ON id.Item = i.ItemId AND id.Store = @Store
JOIN oc.CaseSize cs ON cs.CaseSizeId = id.CurrentCaseSize
JOIN oc.Supplier s ON s.SupplierId = cs.Supplier
JOIN oc.ItemConversionFactor icf ON icf.Item = i.ItemId
JOIN oc.Uom u ON u.UomId = icf.ReportingUom
JOIN oc.Uom u_req ON u_req.UomId = lis.Uom

WHERE r.SendingStore = @Store
  AND lrs.Status <> 'F'  -- Exclude fulfilled
  AND r.DateRequired >= DATEADD(DAY, -30, GETDATE())  -- Limit to last 30 days

ORDER BY r.DateRequired DESC;
