# Google Sheets layout

Generated from `app/lib/sync/sheets_schema.dart` (the app validates the header row of every tab before writing).

Rules:
- **Column A is always the record ID.** Rows are matched by this ID on every sync — never by row number, name or phone.
- Rows are never removed by the app. A record deleted on the phone gets `Deleted = TRUE` and `Deleted At`.
- Money values are numbers (Rs). Dates are `YYYY-MM-DD`; times are local `YYYY-MM-DD HH:MM:SS`.
- Order / Order Items / Payments rows are *financial*: if someone edits them in the sheet, the app reports a conflict instead of overwriting.
- Sync is one-way (phone → sheet). Edits made in the sheet are **not** copied back to the phone.

## Customers

Source: `customers` · 8 columns

| # | Column | Notes |
|---|---|---|
| 1 | Customer ID | Stable record ID (UUID) — the key used to match rows |
| 2 | Name |  |
| 3 | Phone |  |
| 4 | Address |  |
| 5 | Created At |  |
| 6 | Updated At |  |
| 7 | Deleted |  |
| 8 | Deleted At |  |

## Orders (financial)

Source: `documents` · 23 columns

| # | Column | Notes |
|---|---|---|
| 1 | Order ID | Stable invoice/quotation ID (UUID) |
| 2 | Type |  |
| 3 | Number |  |
| 4 | Date |  |
| 5 | Customer ID | Links to Customers → Customer ID (empty for walk-in) |
| 6 | Customer Name |  |
| 7 | Customer Phone |  |
| 8 | Branch |  |
| 9 | Subtotal |  |
| 10 | Discount |  |
| 11 | Tax % |  |
| 12 | Tax Amount |  |
| 13 | Grand Total |  |
| 14 | Paid |  |
| 15 | Balance | Grand Total − Paid |
| 16 | Payment Status |  |
| 17 | Order Status |  |
| 18 | From Quote |  |
| 19 | Note |  |
| 20 | Created At |  |
| 21 | Updated At |  |
| 22 | Deleted |  |
| 23 | Deleted At |  |

## Order Items (financial)

Source: `document_items` · 18 columns

| # | Column | Notes |
|---|---|---|
| 1 | Item ID | Stable order-item ID |
| 2 | Order ID | Links to Orders → Order ID |
| 3 | Order Number |  |
| 4 | Line |  |
| 5 | Product ID | Stable product ID |
| 6 | Description |  |
| 7 | Width |  |
| 8 | Height |  |
| 9 | Measure Unit | `ft` (W×H) or `in` (W×H÷144) |
| 10 | Area per Piece (sq ft) |  |
| 11 | Qty |  |
| 12 | Unit |  |
| 13 | Price Basis |  |
| 14 | Agreed Rate | Rate agreed on this bill (historical; not changed by later rate updates) |
| 15 | Line Total |  |
| 16 | Updated At |  |
| 17 | Deleted |  |
| 18 | Deleted At |  |

## Payments (financial)

Source: `payments` · 13 columns

| # | Column | Notes |
|---|---|---|
| 1 | Payment ID | Stable payment ID — one row per payment |
| 2 | Order ID | Links to Orders → Order ID |
| 3 | Order Number |  |
| 4 | Customer ID | Links to Customers → Customer ID (empty for walk-in) |
| 5 | Customer Name |  |
| 6 | Date |  |
| 7 | Amount |  |
| 8 | Method |  |
| 9 | Note |  |
| 10 | Created At |  |
| 11 | Updated At |  |
| 12 | Deleted |  |
| 13 | Deleted At |  |

## Products & Rates

Source: `products` · 12 columns

| # | Column | Notes |
|---|---|---|
| 1 | Product ID | Stable product ID |
| 2 | Name |  |
| 3 | Category |  |
| 4 | Unit |  |
| 5 | Current Rate |  |
| 6 | Price Basis |  |
| 7 | Stock Item |  |
| 8 | Stock Qty |  |
| 9 | Last Rate Change |  |
| 10 | Updated At |  |
| 11 | Deleted |  |
| 12 | Deleted At |  |

## Daily Expenses

Source: `expenses` · 10 columns

| # | Column | Notes |
|---|---|---|
| 1 | Expense ID | Stable expense ID |
| 2 | Date |  |
| 3 | Category |  |
| 4 | Description |  |
| 5 | Branch |  |
| 6 | Amount |  |
| 7 | Created At |  |
| 8 | Updated At |  |
| 9 | Deleted |  |
| 10 | Deleted At |  |

## Fixed Monthly Expenses

Source: `fixedexpenses` · 12 columns

| # | Column | Notes |
|---|---|---|
| 1 | Fixed Expense ID | Stable fixed-expense ID |
| 2 | Name |  |
| 3 | Category |  |
| 4 | Monthly Amount |  |
| 5 | Branch |  |
| 6 | Active |  |
| 7 | Start Month |  |
| 8 | End Month |  |
| 9 | Note |  |
| 10 | Updated At |  |
| 11 | Deleted |  |
| 12 | Deleted At |  |

## Sync Log

| # | Column |
|---|---|
| 1 | Timestamp |
| 2 | Device |
| 3 | Event |
| 4 | Entity |
| 5 | Record ID |
| 6 | Result |
| 7 | Details |

One summary row per sync run plus a row per conflict or failed write. Never contains tokens or customer financial details beyond record IDs.
