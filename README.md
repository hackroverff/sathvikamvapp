# Sathvika M V Store

A mobile-first, installable inventory and billing PWA for Sathvika M V Provision Store. It uses React/Vite, Supabase Auth + Postgres with RLS, browser camera scanning, SheetJS-compatible Excel/CSV import/export, and Recharts analytics.

## Run locally

```sh
npm install
cp .env.example .env.local
# fill in the Supabase project URL and public anon/publishable key
npm run dev
```

For camera scanning, use HTTPS or `localhost` and allow camera access. On a phone, use the browser's **Install app / Add to Home Screen** option. The service worker caches the app shell; stock additions are queued in local storage while offline and sent to Supabase when the phone reconnects. Other phones see the shared stock after sync (enable Supabase Realtime for live updates while open). Keep browser storage enabled so a phone can retain its pending stock queue.

There is no sample/demo store. The app requires a Supabase project and a real account.

## Supabase setup and first owner

Use a **fresh Supabase project** for this schema. The SQL creates the tables, first-owner bootstrap, bill/FEFO functions, and row-level security policies.

1. In Supabase, create a project. In **Authentication → Providers → Email**, enable email/password sign-in. For the first owner only, turn email confirmation off so the first owner can claim the account immediately.
2. Open **SQL Editor → New query**, paste the complete `supabase/schema.sql`, and run it once. It creates `profiles`, `categories`, `products`, `batches`, `sales`, `sale_items`, and `shop_settings`. The first account is claimed as owner through the database's one-time `claim_first_owner()` function. Auth users created without an owner remain inactive and cannot read store data.
3. Set local environment variables in `.env.local` (or Vercel project settings):

   ```env
   VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
   VITE_SUPABASE_ANON_KEY=YOUR_PUBLIC_ANON_OR_PUBLISHABLE_KEY
   ```

   These are the public browser credentials. **Never** add a Supabase service-role key to `.env.local`, Vite variables, Git, or browser code.
4. Run the app and use **Create owner account** on the first screen. This screen is shown only while there is no active owner. After setup, disable public sign-ups in **Authentication → Settings**; the app has no public sign-up link. Staff accounts are created only through the owner-protected Edge Function.
5. Deploy the staff-admin function from this repository:

   ```sh
   npx supabase login
   npx supabase link --project-ref YOUR_PROJECT_REF
   npx supabase functions deploy staff-admin
   ```

   Supabase supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` to Edge Functions. The service-role key is used only inside the function to create/reset/remove Auth users. Do not expose it to the client.
6. In **Database → Replication**, enable Realtime for `products`, `batches`, and `sales` to refresh already-open phones as changes arrive. Auth password reset redirects must include the deployed site URL in **Authentication → URL Configuration**.
7. Sign in as owner and add staff in **More → Staff accounts**. Each staff account gets an email and temporary password; share the password privately. The staff role is assigned server-side and enforced by RLS.

RLS rules let staff read products/batches, add stock batches, and create bills through the atomic `create_sale` function. Staff cannot insert/edit product prices, update/delete stock, read other staff's sales, cancel bills, manage accounts, or access owner reports/exports. Owners can manage products, correct batches, see all sales, cancel bills, and export. `create_sale` deducts unexpired stock FEFO inside one database transaction; expired/short stock causes the entire bill to fail without partial deduction.

## Import your Excel file

1. Sign in as the owner and open **Stock → Import**.
2. Choose `.xlsx`, `.xls`, or `.csv`. The importer scans the first 50 rows for the best header match, so a title in row 1 and headings in row 3 are okay. Blank rows are ignored.
3. Check **Match your columns**. The headings in your file are recognized: `Item Code`, `Product Name`, `Category`, `Manf Date`, `EXP Date`, `Unit (this is quantity)`, and `Selling Price Per Piece`. Change any dropdown if needed.
4. Review the row counts and reasons. Missing name, price, or units and expiry-before-manufacture need correction. Missing dates and already-expired stock are allowed in, marked **Check dates**. If a barcode repeats with a different product name, edit that row's code before import.
5. Import. Existing barcodes receive another batch; they do not create another product. Download the CSV or Excel template from the import screen at any time.

Accepted dates include Excel date cells, `dd-mm-yyyy`, `dd/mm/yyyy`, and `yyyy-mm-dd`. Numeric/scientific barcodes are expanded to digit text where the source retains those digits. If Excel has already removed leading zeroes from a numeric code, format that source column as Text before saving to preserve them.

## Deploy free on Vercel

1. Push/import this GitHub repository into Vercel and select the **Vite** preset.
2. Set build command `npm run build` and output directory `dist`.
3. Add `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` in Vercel's Environment Variables for Preview and Production, then redeploy.
4. Deploy the Supabase `staff-admin` Edge Function separately as above; Vercel serves the web app and does not host the Supabase service key.
5. Add your Vercel production URL to Supabase Auth's Site URL and Redirect URLs; enable Realtime for the three stock/sales tables.

For camera scanning, the deployed site must be HTTPS. The same Vite build can also be hosted on Netlify (`npm run build`, publish `dist`).

## Main features

- Owner-only first-account setup, email/password sign-in, persistent Supabase session and password reset.
- Owner-managed staff accounts; owner/staff permissions enforced by SQL RLS and security-definer bill functions.
- Stock capture, custom short codes for loose goods, product search, category filters, batch detail/correction, barcode scan, CSV/Excel import with header detection, row mapping and preview, and offline stock queue.
- FEFO cash/UPI billing, optional customer/discount, printable/shareable receipts and searchable bill history with owner cancellation/restock.
- Owner-only real-data sales/stock reports and Excel/CSV downloads, including a multi-sheet full backup.
- English/Tamil language switch for the main navigation and common tasks; installable PWA with offline shell.
