# Sathvika M V Store

A mobile-first installable PWA for a small provision store. Phase 1 is implemented: sample sign-in, product and batch stock entry, barcode scanning, product search/detail, and CSV import with a preview. Home and Stock are designed for touch-first use. Billing and analytics screens are groundwork for later phases.

## Run locally

```sh
npm install
npm run dev
```

For camera scanning, serve over HTTPS (or use localhost). Install on a phone from the browser's **Add to Home Screen / Install app** menu. The PWA shell is cached for offline startup, and stock edits in sample mode are kept in that browser's local storage. While offline, a clear banner is shown. Do not clear browser storage if you need to keep local sample-mode records.

## Sample mode and Supabase

The sign-in page's **Try the sample store** button loads 15 realistic grocery products, batches, and sample sales. It stores data only in this browser. To enable real email/password login, create a Supabase project, apply `supabase/schema.sql` in the SQL editor, then add these Vite environment variables (for example in `.env.local`):

```env
VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_PUBLIC_ANON_KEY
```

Never put a Supabase service-role key in browser code. With those variables set, the app uses Supabase Auth and reads/writes products and batches in Supabase. Without them, it runs in local sample mode. Offline edits in local sample mode persist on the device; database-backed offline write queuing/synchronization is not included yet. The SQL below establishes tables, roles, and row-level access policies.

## Supabase setup outline

1. Create a Supabase project and enable Email authentication.
2. Run `supabase/schema.sql` in SQL Editor.
3. In `profiles`, assign the account creating the store the `owner` role (see SQL comments); new staff should be invited then set to `staff` by the owner.
4. Set the environment variables above and deploy the Vite app. For production, configure email confirmation and password reset in Supabase Auth.

## Deploy free

- **Vercel:** import this repository, framework preset **Vite**, build command `npm run build`, output directory `dist`; set the two `VITE_SUPABASE_*` environment variables if using Supabase.
- **Netlify:** import the repository, build command `npm run build`, publish directory `dist`; add the same environment variables. The root `index.html` fallback is handled for this single-page app.

## Phase 1 notes

- Add stock supports barcode/custom short code, product details, month-level manufacture/expiry, batch quantity, and repeated **Save & scan next** entry.
- Existing codes fill known product details. Batches are stored separately per product.
- Find supports name, barcode and category. Product details allow price and batch corrections. Owner can remove a product with confirmation; records can be restored immediately with Undo.
- CSV import has a downloadable template, preview and validation. Headers: `barcode,name,category,mrp,mfg_date,expiry_date,units`.
- Camera scan uses `html5-qrcode`; browser camera permission and HTTPS are required. Manual code entry is always available.
- Staff demo role hides owner-only reports and exports; staff account administration and database-backed authorization are reserved for Supabase integration.
