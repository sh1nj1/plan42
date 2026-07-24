# CloudFront behavior — /public-assets/*

Collavre's externally-public attachments (landing-page assets, etc.) are served
from `/public-assets/blobs/:signed_id/*filename`. `PublicAssetsController` forces
`Cache-Control: public, max-age=31536000, immutable`, so CloudFront can cache
them safely.

## CloudFront cache behavior to add

Add a single behavior to the existing distribution that fronts Rails:

- **Path pattern:** `/public-assets/*`
- **Origin:** existing Rails origin
- **Viewer protocol policy:** Redirect HTTP to HTTPS
- **Allowed methods:** GET, HEAD
- **Cache policy:** Managed-CachingOptimized (or equivalent long-TTL: min 1d, default 1y, max 1y)
- **Origin request policy:** Managed-CORS-S3Origin (forward only the Host header; do not forward cookies or Authorization)
- **Compress objects automatically:** Yes

## Environment variable

- `PUBLIC_ASSETS_HOST` (optional) — CloudFront domain. When set, the `url`
  returned by the MCP tools is an absolute URL
  (`https://cdn.example.com/public-assets/...`). When unset, the URL is
  origin-relative.

## Cache invalidation

The `signed_id` is deterministic from the blob's identity, and re-attaching an
attachment produces a new `signed_id`, so cached entries are naturally replaced
without explicit invalidation. To invalidate intentionally, remove and re-attach
the attachment.

## Authorization model

`/public-assets/*` is **accessible without authentication**. The `signed_id` is
the only capability. If you need access-controlled assets, keep using the
existing `rails_blob_path` (engine-internal callers) — that route is not covered
by the CloudFront cache behavior above.
