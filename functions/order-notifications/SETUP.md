# Activate AppleSpace order notifications

The implementation is deployed but sending starts OFF. Do not put credentials in GitHub or browser code. A phone number alone cannot activate WhatsApp Cloud API.

1. Connect the new number to a Meta WhatsApp Business Account and complete Meta's verification/registration. Obtain the Phone Number ID (not the phone number), production access token with WhatsApp messaging permission, App Secret, and an appropriate supported Graph API version.
2. Add these secrets in Supabase → Edge Functions → Secrets: `WHATSAPP_ACCESS_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_APP_SECRET`, `WHATSAPP_VERIFY_TOKEN` (random secret you choose), `WHATSAPP_GRAPH_VERSION` (e.g. the supported version selected for your Meta app), `ORDER_NOTIFICATION_CRON_SECRET` (independent random secret of at least 32 bytes). Keep `WHATSAPP_LIVE_ENABLED=false` until testing and template approval finish.
3. Set Meta webhook callback to `https://ghmofddxpflpopwavysk.supabase.co/functions/v1/order-notifications/webhook`. Use your verification token, then subscribe the app to the account's messages events. POST signatures are checked against the App Secret and the sender Phone Number ID is validated.
4. Create and obtain approval for six **utility** templates in language **English (en)**, named below. Each has five positional body parameters: customer name, order reference, items, merchandise subtotal, status details. Use the exact parameter order. Keep promotional offers separate.
5. Configure the scheduler with `scheduler.sql`. Store its cron secret in Supabase Vault, using the same value as `ORDER_NOTIFICATION_CRON_SECRET`. Never paste actual tokens into repository files. Schedule runs every minute, claims three jobs per invocation. No visitor needs to keep the website open.
6. Enable `WHATSAPP_LIVE_ENABLED=true`, then enable new order notifications in Website manager → Messages. Place a new test order with your own number and optional WhatsApp checkbox checked. Test confirmation, courier/tracking, completion, cancellation and STOP; verify accepted → sent → delivered/read webhook updates. Disable live sending immediately if configuration is wrong.

Messages created while setup is disabled are labelled **Setup required** and are NOT automatically sent later. Old orders are never backfilled. Queued messages expire after 24 hours and unsent older statuses are superseded. Old/non-consenting orders never receive automatic messages. STOP or UNSUBSCRIBE suppresses future messages to the number; re-enrolment is deliberately manual after fresh permission.

## Approved template copy to submit

Use this body for each template, replacing the heading with the indicated one:

```
AppleSpace — ORDER HEADING
Hi {{1}}, your order reference is {{2}}.
Items: {{3}}
Merchandise subtotal: {{4}}. Delivery charges, if applicable, are confirmed separately.
{{5}}
This is an order update, not proof of payment. Reply here for help or STOP to stop WhatsApp updates.
```

| Template | Heading |
|---|---|
| aspace_order_pending_v1 | Request received |
| aspace_order_confirmed_v1 | Order confirmed |
| aspace_order_dispatched_v1 | Order dispatched |
| aspace_order_completed_v1 | Order completed |
| aspace_order_cancelled_v1 | Order cancelled |
| aspace_order_return_pending_v1 | Delivery update |

Example parameters: `Test Customer`, `A1B2C3D4`, `iPhone 13 Pro x 1`, `PKR 100000`, `Confirmed and reserved. Contact the shop to arrange collection.`

## Operations

Manager → Messages shows the latest 100 events and provider outcomes. API acceptance is not delivery. Explicit rate-limit rejection retries with backoff, at most four attempts; uncertain outcomes never auto-resend. This reduces duplicates but cannot guarantee exactly-once delivery across network failures. Investigate unknown/failed messages before contacting the customer manually. Provider error codes are stored without credentials or raw webhook bodies. Disable the owner toggle to stop new dispatch; already accepted messages cannot be recalled.

The existing stock mechanism remains: request → manager confirmation/reservation → dispatch → delivery/collection → ERP sale. Sending a notification never confirms stock, records payment or creates a sale. A downloadable tax/payment receipt is not included; these messages confirm order status only.
