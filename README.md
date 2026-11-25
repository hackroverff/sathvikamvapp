# Sathvika M V Store

A mobile-first, installable inventory, billing, supplier-dues and customer-credit PWA for Sathvika M V Provision Store. It uses React/Vite, Supabase Auth + Postgres with row-level security, barcode scanning, Excel/CSV import/export and Recharts.

## Run locally

```sh
npm install
cp .env.example .env.local
# Add the Supabase project URL and public anon/publishable key
npm run dev
```

For camera scanning, use HTTPS or `localhost` and allow camera access. On a phone, use **Install app / Add to Home Screen**. Stock additions can be queued locally while offline and sent to Supabase on reconnect. Purchase bills, supplier/customer payments, and credit bills require an internet connection. Enable Supabase Realtime for `products`, `batches` and `sales` to refresh already-open devices.

There is no seeded sample/demo store. Use only real store data.

## Supabase: fresh project setup

1. Create a Supabase project. Enable email/password sign-in under **Authentication → Providers → Email**. For first-owner setup, temporarily disable email confirmation.
2. Open **SQL Editor → New query**, paste the complete `supabase/schema.sql`, and click **Run**. It creates the final v5 tables, RLS policies, grants, owner bootstrap, import undo, staff activation and FEFO billing functions. It does not insert sample products or sales.
3. Set these public browser values in `.env.local` (and later in Vercel):

   ```env
   VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
   VITE_SUPABASE_ANON_KEY=YOUR_PUBLIC_ANON_OR_PUBLISHABLE_KEY
   ```

   Never put the Supabase service-role key in Vite variables, Git, the browser, or chat.
4. Start the app and use **Create owner account**. The first signed-in account claims the one-time owner role through `claim_first_owner()`. Then disable public sign-ups under **Authentication → Settings**.
5. For owner password resets, allow the deployed site URL in **Authentication → URL Configuration**. Enable Realtime for `products`, `batches`, and `sales` under **Database → Replication**.

## Upgrade an existing database (important)

Do **not** run the fresh schema over an existing store. Back up the production database and apply the migrations in order in **Supabase Dashboard → SQL Editor**:

1. If the database is still on v2, choose **New query**, copy the complete `supabase/migration_v3.sql`, paste it, click **Run**, and wait for success.
2. If the database is on v3, choose **New query**, copy the complete `supabase/migration_v4.sql`, paste it, click **Run**, and wait for success. Skip this step for databases already on v4 or created from the existing fresh schema.
3. Choose **New query** again. Copy the complete `supabase/migration_v5.sql` from this repository into the SQL Editor and click **Run**. Wait for the success result before opening the updated app. V5 adds private cost records/RPCs, vendor association and return/restock tables/functions, return and urgent-expiry settings, MRP snapshot markers, and explicit column-level grants so staff API reads cannot expose legacy buying-cost columns. The migration is additive/idempotent and contains no sample inserts.
4. Reload the app. Do not run `supabase/schema.sql` on an existing store.

For a brand-new Supabase project, use `supabase/schema.sql`; it contains the final v5 schema overlay. This workspace cannot execute SQL against your live Supabase project, so verify migrations, Auth, billing and owner/staff RLS in a non-production project first. Real-database tests have not been performed here.

## Pricing, suppliers, returns and expiry

- Customer savings = `(MRP − selling price) / MRP × 100`; unit profit = `selling price − buying price`; profit % = `unit profit / selling price × 100`; markup % = `unit profit / buying price × 100` (shown on owner product detail). Selling price cannot exceed MRP.
- Buying costs live in owner-only tables. The v5 migration removes authenticated access to legacy cost columns from products, batches and sale lines, and grants read access only to explicit public columns. Owner screens use owner-checking RPCs; the security-definer sale function reads costs internally. Staff product/batch/receipt reads do not include costs.
- **More → Dues → Suppliers** opens vendor detail, adjusted balances, linked products, realized profit on costed sales, and estimated current-stock profit. Owner quick-fill assigns missing buying costs. Product import recognizes buying/purchase cost and supplier/vendor columns; unknown supplier names are created for owner imports.
- Owner product details and bulk editing support vendor assignment. The supplier return screen records partial quantities, stock deductions, rejected return restorations, settlement method and credits against oldest open supplier bills. Return windows can be configured in **More → Settings**.
- Urgent and soon expiry windows are configurable. Staff see only safe inventory attention counts/names, never supplier money. Owners can add restock requests, mark progress and share the active list through WhatsApp. Reports include return-credit and write-off totals.

## Staff accounts without deploying an Edge Function

The owner can open **More → Staff accounts → Open staff setup help**. The screen includes exact SQL Editor steps and a copyable SQL script that creates a confirmed Auth user and active staff profile using an email and temporary password. Replace the example email, password and name before running it. Use a fresh email, keep the temporary password private, and have the staff member change it after sign-in. This script writes to Supabase Auth tables directly, so use the version shown by the app and test it in a non-production project first if your Supabase Auth schema has customizations.

Use **Deactivate** or **Reactivate** in the staff list at any time. Deactivation is done by an owner-checked database function and immediately prevents the staff profile from accessing store data. For password resets, use Supabase **Authentication → Users** or the app’s Forgot password flow.

Staff can read products/prices, search and scan, bill, add stock batches, and add customer identities. Staff cannot edit product details/prices, edit or correct existing batches, adjust stock, bulk edit, hide, or delete products; those write restrictions are enforced by RLS (not just hidden controls). RLS also denies staff access to supplier money screens, reports, exports, customer balances, and customer payment history. Staff customer queries are restricted to the `id`, `name`, and `phone` columns.

Product changes and owner stock adjustments are retained in `product_changes` and `stock_adjustments`, shown on product details, and included in exports/full backups. Products with sales cannot be deleted; owners can hide them from working lists while keeping historical bills and reports intact. A hidden product can be restored with **Show hidden**.

## Import stock

1. Sign in as owner and open **Stock → Import file**.
2. Select `.xlsx`, `.xls` or `.csv`. The importer searches the first 50 rows for headings, so a title and blank rows above row 3 are okay.
3. Check column matches and preview row reasons. Missing/expired dates are warnings; missing required product/price/quantity or invalid dates need attention.
4. If a barcode exists, choose **Add as new delivery**, **Set stock to match this file**, or **Skip existing products** (the default). The app flags matching file hashes and row sets, displays import progress and a final created/updated/skipped/failed summary, and offers **Undo this import** for 10 minutes.
5. Header-only CSV/Excel templates are available from the import screen. Excel date cells, Excel serial dates and common day/month date strings are supported. Numeric/scientific barcode values are expanded where the source retains all digits; use Text formatting in Excel if leading zeroes matter.

Expired quantities are excluded from current stock and value calculations. Owners can remove expired stock from the red Home card; the original quantity, batch/product details and removal time are retained in `expired_stock_removals`.

## Supplier purchases and customer credit

- Owners may add a supplier purchase bill during stock entry, associate batches to it, record paid-now amounts and optional reminder dates, and save cost price per batch.
- **More → Dues** shows unpaid/part-paid bills, reminder-based overdue totals, due-this-week totals, payment history and partial payment controls. A canceled purchase asks whether linked stock should also be zeroed.
- **Bill → Credit** requires a customer and supports a paid-now amount. **More → Customers** shows owner-only balances, credit bills and payments; staff can create/identify customers but cannot see this ledger.
- Credit bills remain sales on their bill date. Customer repayments are reported separately from Cash, UPI and Credit given.

## Deploy free on Vercel

1. Import this GitHub repository into Vercel and choose the **Vite** preset.
2. Set build command `npm run build` and output directory `dist`.
3. Add `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` for Preview and Production, then redeploy.
4. Add your production URL to Supabase Auth’s Site URL and Redirect URLs; enable Realtime as above. No Edge Function deployment is required for staff creation/deactivation.

Camera scanning requires HTTPS. The same Vite build can be hosted on Netlify with `npm run build` and `dist` as the publish directory.

## Main features

- Owner-first authentication, persistent sessions, password reset, owner/staff role checks and SQL RLS.
- Two-price products with printed MRP and selling price, savings-aware bills/receipts, customer-savings and owner-only profit calculations, supplier associations, and owner-only buying costs.
- Barcode scanning, inventory search/sorting, stock batches, category limits, grouped expiry alerts and offline stock queue.
- Owner-only product editing, soft hide/restore for products with sales, audited stock corrections and batch history, and preview/undo bulk changes.
- Excel/CSV imports with MRP, selling-price, purchase-cost and supplier mappings, validation, repeat-import detection, duplicate-barcode choices, progress and time-limited undo.
- FEFO Cash/UPI/Credit billing, customer selection, receipts, searchable history and owner cancellation/restock.
- Supplier purchases/dues, partial returns and credits, restock tracking, customer balances and payments.
- Owner-only reports, CSV/XLSX exports and a full multi-sheet backup including supplier/customer ledgers.
- English/Tamil navigation and installable PWA shell.

## Verification and limits

`npm run build` is the current local build check. The SQL migration, Auth-table staff script, RLS behavior, concurrent payment/billing behavior, and all Supabase reads/writes need testing against a non-production Supabase project before rollout. This app has not been tested against a live Supabase database or deployed from this repository. The build currently reports a large-chunk warning for Excel/chart bundles; it still completes successfully.
