# ASPACE storefront

The ASPACE website lives in **shayyan111/AppleSpace**. The separate AppleSpace-Management repository remains the ERP application.

A buildless, responsive storefront in charcoal and light gray. Pages: Home, iPhones, iPads, Accessories, Reviews, Support, About Us, product details, shopping bag, checkout and `/manager/`.

## Deploy

Vercel: connect this repository, select **Other**, leave the build command empty, and use the repository root as the output directory. No environment variables or Node build are needed. `vercel.json` supplies clean URLs and security headers. If the project currently uses an old framework preset or build command, reset those settings to the static configuration above.

The database connection uses the existing Supabase project's **publishable** key. It is safe to expose only because authorization is enforced by the database. No service-role keys, ERP credentials or purchase costs are shipped to the browser.

## Website workspace

Open `/manager/`. The ERP owner can sign in with the existing Supabase account. To authorize another person, create a separate account in Supabase Authentication, without an active ERP profile, then grant website access from the owner's **Manager access** tab. Access can be disabled there too. No website managers were automatically created or granted access by this update.

The workspace shows unsold listing fields and selling prices, supports up to eight actual product photos per listing, website title/description, publication, order-request status, and genuine customer reviews with permission. It uses `store_portal`, `store_update`, `store_reviews` and `store_review_update`; it never reads raw inventory, purchases or profit records.

Public products come exclusively from `store_catalog`. iPads are inventory devices identified by their model/title; they retain the ERP's `iphone` inventory-source kind for updates and checkout. Accessories use the separate accessory inventory. Sold, unavailable and hidden stock is excluded by the database. The initial public catalog is empty because no stock is published; select stock to publish from the workspace.

Photos uploaded to the `website-products` bucket are public product assets. Do not upload seller photos or private records. Removing a photo detaches it from a listing; it does not remove the underlying storage object.

## Checkout

Shopping bag selections are stored locally on the visitor's device. At submission, `store_checkout` validates the current public availability, stock quantity and selling price from the central ERP database and records an order request. Requests are idempotent and rate-limited by the database. They **do not collect payment, reserve stock or record an ERP sale**. Complete sales in the ERP so stock is updated everywhere.

## Reviews

Only consented, published feedback is public. There are no invented testimonials or seeded ratings. Customers can share feedback on WhatsApp; an authorized manager can add the genuine feedback, record permission and publish it in the workspace.

## Checks

Run `node --check app.js`, `node --check manager.js` and `node --check database.js`. Additional verification covers page/asset links, public catalog access, unauthorized portal access and database authorization for website managers. See `database/` for the additive reviews migration and rollback-only permission checks. Existing inventory tables, ERP roles and website functions are reused.
