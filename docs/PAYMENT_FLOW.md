# Payment flow

The mobile app should not ask the customer to copy a VPN link manually.

## Current app flow

1. App calls `POST https://ironvpn.shop/api/create-payment.php`.
2. Site API returns:
   - `orderId`
   - `accessToken`
   - `confirmationUrl`
3. App stores `orderId + accessToken`.
4. App opens `confirmationUrl` in the external browser/payment page.
5. When the customer returns to the app, it calls:

```text
GET https://ironvpn.shop/api/order.php?order=ORDER_ID&token=ACCESS_TOKEN
```

6. If the order is `fulfilled`, the app receives `vpnLink`, parses it and configures VPN automatically.

## Optional smoother return

Add a button on `success.html`:

```text
ironvpn://order?order=ORDER_ID&token=ACCESS_TOKEN
```

Android is already configured to receive:

- `ironvpn://order?...`
- `https://ironvpn.shop/success.html?order=...&token=...`

iOS is configured for:

- `ironvpn://order?...`

For iOS universal links, add Associated Domains later:

```text
applinks:ironvpn.shop
```

and publish `apple-app-site-association` on the site.

## App Store note

The current implementation uses an external website/payment page instead of Apple In-App Purchase. Before App Store release, check whether the final commercial model is accepted for the selected app category and region.
