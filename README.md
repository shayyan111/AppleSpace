# Apple Space online store

Static storefront and website-management portal connected to the existing AppleSpace Supabase inventory. No separate stock database, build framework or browser service key is used.

## Pages

- `index.html`: Home
- `iphones.html`: Available, published phones with search, PTA filters and sorting
- `accessories.html`: Available, published accessories
- `product.html`: Product specifications and photo gallery
- `about.html`: Shop front, inner office, address and contact links
- `cart.html`: Persistent cart and order-request checkout
- `admin.html`: Authenticated product-publication, photos, orders and owner-only access management
- `coming-soon.html`: Preserved previous homepage

## Shared inventory

The database project is `ghmofddxpflpopwavysk`. Phones come from `public.inventory_items`; accessories come from `public.accessories`.

A phone appears publicly only when its status is `in_stock`, `show_on_website` is enabled, and its website/default selling price is positive. Sold and reserved phones are excluded. Accessories require positive stock, a positive selling price and publication enabled. Website managers cannot create stock or change stock quantity.

No purchase price, supplier, purchase record, full IMEI, internal note or profit field is returned to the website portal. A dedicated website manager has a private membership and **no active ERP user profile**. Never reuse an ERP owner/manager account for a person who should not see business costs: those accounts retain their existing ERP permissions.

`database/website-schema.sql` is the one-time installation script for the additive website tables/functions and photo bucket. It was applied to the connected database during implementation. **Do not run it again** on that project. `database/verify-website.sql` runs transactional security and checkout checks and rolls its fixtures back.

The private schema is not a PostgREST exposed schema. Public RPCs run as invoker and delegate to narrowly scoped private functions with explicit field whitelists and authorization. Website managers cannot use the raw inventory or ERP RPC to retrieve costs.

## First login and team setup

1. Open `/admin.html` and sign in with the existing **owner** account.
2. To add a website manager, create a separate user in **Supabase → Authentication → Users**. Set up their confirmed email/password or invitation. Do not add an active row for them to ERP `user_profiles`.
3. In the website portal, open **Website team**, enter that email and click **Grant website access**.
4. The manager signs in at `/admin.html` with their own account. Access can be disabled from Website team; this is checked on every protected request.
5. Under **Product listings**, open an available inventory item, set its public title, selling price and description, upload photos, and enable **Display this product on the website**. Publication is opt-in; existing products were left hidden.

Images: up to eight photos per product, JPG/PNG/WebP, 5 MB each. Photos are stored in `website-products`; authenticated website managers can upload only into their own user-ID prefix. Images are intentionally public product assets. Removing a photo from a listing detaches it immediately; an object uploaded by another manager may remain in storage, since managers can delete only their own objects.

## Orders and payment

Checkout creates an **order request**, not a completed stock sale. It validates customer details, current publication/stock, quantity and selling price server-side. A UUID request ID makes retries idempotent. Database totals ignore client calculations; changed prices require refreshing the cart. Duplicate lines, excessive quantities and unavailable products are rejected. Submission is limited to five requests per customer phone per hour.

No online payment is collected. Pickup or delivery is requested; delivery charges and payment details are confirmed by staff. Portal order status changes do not reserve or sell stock. Record the actual sale in the ERP to reduce stock. Two pending requests may reference the same phone, so staff must confirm availability before accepting payment. Payment gateway integration and automated reservation require a separate business decision.

The public catalogue is fetched at page load, when returning to a catalogue tab and every 30 seconds while browsing. Checkout revalidates at submission. The cart's **Refresh prices & stock** button reconciles its current selections.

## Run and deploy

Use `npm start` (Python 3) or another static HTTP server; ES modules require HTTP rather than opening files through `file://`. Run `npm test` for cart/state/escaping tests.

Vercel: select the `shayyan111/AppleSpace` repository, use **Other** framework, leave build command empty, and use `.` as the output directory. The existing static project can deploy this branch as a preview. Review the branch/PR before merging into `main`, which may trigger the production deployment.

`config.js` contains only the public project URL and publishable API key. It must never contain a service-role/secret key. Authentication tokens stay in session storage and refresh as needed; logout removes them. The Supabase project must keep private schemas unexposed and its current inventory/ERP row policies enabled.

## Verification

- Node tests: unavailable/hidden product removal, stock quantity caps, fresh prices and output escaping.
- Database tests: website-manager costs/ERP isolation; anonymous portal denial; publication/hiding; sold stock exclusion; checkout totals, quantity and price rejection; duplicate retry handling.
- Browser checks passed on desktop and 390px mobile: catalogue filters/sorting, cart quantity cap, checkout submission, portal login, listing edits, photo upload, preservation of unsaved listing text, owner access management and logout. Browser API responses were mocked for interaction tests; the database tests independently exercised real authorization and checkout.
- Live public REST catalogue request returned HTTP 200. The initial catalogue is intentionally empty until available stock is published.


### Storefront visual design
The storefront uses a dark burgundy identity, a CSS 3D phone concept (back-to-front rotation), animated editorial strip, scroll reveals, responsive product cards, and prominent shop photography. The phone is decorative concept artwork, not an inventory product or an official device render. Animations respect reduced-motion preferences and the homepage has a pause control. Styles are scoped to storefront pages so the website management portal stays legible.

Visual verification covered desktop and mobile widths, scrolling reveals, and reduced motion. Existing catalog, checkout, and manager browser flows still pass with mocked API data; inventory permissions and database functions were unchanged in this design update.
