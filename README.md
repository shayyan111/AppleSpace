# AppleSpace storefront

The AppleSpace website lives in **shayyan111/AppleSpace**. The separate AppleSpace-Management repository remains the ERP application.

A buildless, responsive storefront in charcoal and light gray. Pages: Home, iPhones, iPads, Accessories, Reviews, Support, About Us, product details, shopping bag, checkout and `/manager/`.

## Deploy

Vercel: connect this repository, select **Other**, leave the build command empty, and use the repository root as the output directory. No environment variables or Node build are needed. `vercel.json` supplies clean URLs and security headers. If the project currently uses an old framework preset or build command, reset those settings to the static configuration above.

The database connection uses the existing Supabase project's **publishable** key. It is safe to expose only because authorization is enforced by the database. No service-role keys, ERP credentials or purchase costs are shipped to the browser.

## Website workspace

Open `/manager/`. The ERP owner can sign in with the existing Supabase account. To authorize another person, create a separate account in Supabase Authentication, without an active ERP profile, then grant website access from the owner's **Manager access** tab. Access can be disabled there too. No website managers were automatically created or granted access by this update.

The workspace shows unsold listing fields and selling prices, supports up to eight actual product photos per listing, website title/description, publication, order-request status, and genuine customer reviews with permission. It uses `store_portal`, `store_update`, `store_reviews` and `store_review_update`; it never reads raw inventory, purchases or profit records.

Public products come exclusively from `store_catalog`, combining eligible ERP stock with published website-only on-demand listings. iPads are inventory devices identified by their model/title; they retain the ERP's `iphone` inventory-source kind for updates and checkout. Accessories use the separate accessory inventory. Sold, unavailable and hidden ERP stock is excluded by the database. Website-only listings have no inventory quantity and are explicitly marked on demand. The initial public catalog is empty because no stock is published; select stock to publish from the workspace.

Photos uploaded to the `website-products` bucket are public product assets. Do not upload seller photos or private records. Removing a photo detaches it from a listing; it does not remove the underlying storage object.

## Checkout

Shopping bag selections are stored locally on the visitor's device. At submission, `store_checkout` validates the current public availability, stock quantity and selling price from the central ERP database and records an order request. Requests are idempotent and rate-limited by the database. They **do not collect payment, reserve stock or record an ERP sale**. Complete sales in the ERP so stock is updated everywhere.

## Reviews

Only consented, published feedback is public. There are no invented testimonials or seeded ratings. Customers submit reviews on `/reviews/`. Each submission is pending and invisible online until a website manager approves it in `/manager/`. Managers can approve, reject or unpublish. Public reviews show the server-recorded publication date and time in Pakistan time (PKT). Customer phone numbers are private and visible only to authorized managers. Submissions require consent, use a honeypot, support retry-safe request IDs and allow at most three submissions per contact number per 24 hours.

## Checks

Run `node --check app.js`, `node --check manager.js` and `node --check database.js`. Additional verification covers page/asset links, public catalog access, unauthorized portal access and database authorization for website managers. See `database/` for the additive reviews migration and rollback-only permission checks. Existing inventory tables, ERP roles and website functions are reused.

The About page is served as full content at both `/about/` and `/about.html` to avoid clean-URL redirect loops.

### Review WhatsApp opt-in

The optional, unchecked WhatsApp checkbox sends a boolean `whatsapp_opt_in` with review submissions. `database/website-review-whatsapp-opt-in.sql` runs after `database/customer-review-submissions.sql`. Only opted-in new contacts are inserted into the shared ERP customers table, so they appear in Customer messages after refresh. Existing contacts are matched by normalized phone number without overwriting their name, notes, purchase history or balances. Consent and its timestamp are recorded on the review and customer, and the review links to the customer ID. Unchecked submissions do not create new customers or revoke an earlier opt-in. Existing reviews are not retrospectively enrolled. Public review responses exclude contact and consent fields. `database/verify-review-whatsapp-opt-in.sql` tests anonymous submission, customer linking, normalized-number matching, retry safety, unchecked consent, moderation and RLS privacy inside a rollback-only transaction.

## Store policies

Static `/privacy/`, `/returns/`, `/shipping/` and `/terms/` pages describe the current order-request checkout, review moderation and optional WhatsApp opt-in. Linked from the shared footer, compact Home links, checkout, review form and Support. Product-specific return periods, checking warranties, delivery fees and delivery estimates are confirmed in writing before purchase; no fixed amounts or deadlines are invented. Update these pages when store arrangements or payment methods change.

## On-demand products

Manager → On-demand products → Add on-demand product. Supports category, model, title, optional indicative selling price (blank displays Ask for price), storage, colour, condition, network status, known battery health, description, publication and up to eight photos. Create, edit, hide and delete are checked by the existing database website-manager authorization. `database/website-on-demand-products.sql` adds private website-only storage and extends the safe catalog and update functions. It never inserts ERP inventory, accessories or purchase records. Public cards/detail/search mark these as on demand and use WhatsApp enquiries; client and database reject stock-checkout attempts. Photos use the existing public product bucket and support cover/remove actions. `database/verify-website-on-demand.sql` checks the full workflow, photo limits, access control, checkout rejection and ERP isolation in a rollback-only transaction. No example on-demand products are automatically published.

On-demand creation accepts up to eight photos in the initial form. Photos upload after a hidden listing is created; selected publication proceeds only after uploads succeed. A partial upload leaves the saved product hidden for completion in the editor. `database/website-on-demand-price-label.sql` adds the customizable quote text, defaulting to Call us for price, used when no numeric price is set.

## Customer accounts and protected product photos

Customer accounts use a separate browser session from manager accounts. `/account/` supports email/password signup, login, password recovery, contact/address editing, saved products and the latest 100 orders placed while signed in. Guest orders remain supported; old orders are not claimed by matching a phone number.

Before public customer onboarding, verify Supabase Authentication → URL Configuration allows the exact production origin plus `/account/` (and the private Sites preview origin if used). Configure a production SMTP sender for confirmation and recovery emails; the default Supabase sender has recipient/rate restrictions. Keep email confirmation enabled. Test confirmation and password recovery end to end with an email you control. Do not add customer accounts to ERP staff profiles.

Database scripts: `database/customer-accounts.sql`, `customer-staff-isolation.sql`, `protected-photos.sql`. The verification SQL uses rollback-only test data. Staff isolation explicitly rejects missing roles in existing ERP purchase/accessory functions.

Deploy `functions/product-photo/index.ts` and `watermark.ts` together as the `product-photo` Supabase Edge Function, with gateway JWT verification disabled because the handler validates the publishable API key and checks publication permissions through PostgREST. Staff JWTs are verified by PostgREST and checked by the manager authorization function. The service key comes only from the server environment. Never put it in client files.

Product-photo serves compressed, permanently watermarked JPEG previews and stores them under `website-products/__watermarked/v1/`. Authorization is checked before reading cached previews. Original objects remain in the private bucket. Unpublishing blocks future preview requests, but already downloaded images cannot be recalled. Public product images can always be saved/screenshotted; this feature protects original storage URLs and unpublished files, not the visible image from copying.

Rollout: deploy the resolver and function, then both storefront hosts, then replace catalog paths with opaque IDs and set the website-products bucket private. Browser images use document-local blob URLs. Old public URLs may stay in existing browser/CDN caches until their cache entries expire. Product uploads remain compressed before storage.
