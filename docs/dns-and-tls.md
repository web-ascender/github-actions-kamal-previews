# DNS and TLS

The TL;DR:

- **Wildcard DNS** (`*.preview.example.com → <staging IP>`) is the
  default and works out of the box.
- **Per-host TLS** (Let's Encrypt HTTP-01 via `kamal-proxy`) is the
  default for certificates and works fine for typical PR volumes.
- **Wildcard TLS** is possible but requires DNS-01 challenges and a
  separate ACME tool — `kamal-proxy` doesn't issue wildcards itself.
- **Cookie-domain footgun:** never set `Domain=.preview.example.com` on
  cookies in your preview apps.

## Wildcard DNS

Add a single record at your DNS provider:

```
*.preview.example.com.  IN  A      <IPv4 of staging host>
*.preview.example.com.  IN  AAAA   <IPv6, optional>
```

Or, if you front everything with a load balancer / Cloudflare:

```
*.preview.example.com.  IN  CNAME  staging-lb.example.com.
```

Once the wildcard is in place, every new branch slug resolves
automatically — kamal-previews never needs to provision DNS records.

## Per-host TLS via kamal-proxy (default)

`kamal-proxy` (the proxy that ships with Kamal 2) speaks Let's Encrypt's
HTTP-01 challenge. Each per-PR app declares its own `proxy.host:`, and
`kamal-proxy` requests a fresh certificate on first deploy.

This works as long as:

1. Port 80 is reachable from the public internet (Let's Encrypt's HTTP-01
   challenge fetches `http://<host>/.well-known/acme-challenge/...`).
2. The DNS wildcard is in place (otherwise the challenge can't reach
   port 80).

**Rate limits.** Let's Encrypt allows 50 certificates per registered
domain per week and 300 new orders per 3-hour window. For a team that
opens fewer than ~20 PRs/day this is plenty of headroom. If you bump
into the limits, see "wildcard TLS" below.

## Wildcard TLS via DNS-01

`kamal-proxy` doesn't speak DNS-01, but you can issue the wildcard
certificate out-of-band and feed it into Kamal as a custom certificate.

1. Run `acme.sh` or `certbot` on the deploy host (or anywhere with DNS
   API credentials):

   ```bash
   acme.sh --issue \
     --dns dns_cf \
     -d 'preview.example.com' \
     -d '*.preview.example.com' \
     --keylength ec-256
   ```

2. Add the resulting `fullchain.pem` and `privkey.pem` to your Kamal
   secrets bag.

3. Set `proxy.ssl: { certificate_pem: "${WILDCARD_CERT_PEM}",
   private_key_pem: "${WILDCARD_KEY_PEM}" }` in your base
   `deploy.staging.yml`.

4. Set up a renewal cron (`acme.sh` ships its own; add a Kamal-deploy
   hook to refresh the secret).

When you go this route, `kamal-proxy` no longer requests certs itself.

## Cookie-domain footgun

This bites people surprisingly often. By default, Rails session cookies
have **no `Domain=` attribute** — they're scoped to the exact host the
response came from. That's the safe default. Two preview apps on
`a.preview.example.com` and `b.preview.example.com` cannot read each
other's cookies.

But if your `production.rb` or `staging.rb` does this:

```ruby
Rails.application.config.session_store :cookie_store,
  key: "_myapp_session",
  domain: ".example.com"           # ← BAD when the same code runs in preview
```

…then every preview app is now writing cookies under
`Domain=.preview.example.com`, *and* sharing them with every other
preview. Worse, an XSS in one preview can read sensitive data from any
other.

The fix is environment-dependent. Either:

```ruby
# Don't set Domain= in the preview environment.
config.session_store :cookie_store, key: "_myapp_session",
  domain: ENV["FEATURE_BRANCH"] == "true" ? :all : ".example.com"
```

…or scope the cookie to the exact host:

```ruby
config.session_store :cookie_store, key: "_myapp_session",
  domain: nil  # use the request host
```

`FEATURE_BRANCH=true` is set automatically by kamal-previews' generated
deploy file, so you can branch on it.

## Custom DNS per branch (instead of wildcard)

If you want explicit DNS records per preview (e.g. to route through
Cloudflare with per-host page rules), call your DNS provider's API from a
custom workflow step before the deploy. You'll lose some of the simplicity
but gain visibility / per-branch policy control.

A built-in Cloudflare DNS provisioning hook is on the roadmap; for now,
add it as a custom step in your calling workflow before the
`kamal-previews` reusable-workflow call.
