# CloudFront behavior — /public-assets/*

Collavre serves attachments from `/public-assets/blobs/:signed_id/*filename`.
The `signed_id` only identifies the blob; it is **not** a capability.
`PublicAssetsController` decides per request:

- **Public blob** (readable anonymously: attached to a publicly shared creative,
  a user avatar, ...) — streamed with
  `Cache-Control: public, max-age=3600, s-maxage=86400`, so CloudFront can
  cache it.
- **Any other blob** — `302` to `/rails/active_storage/blobs/proxy/...` with
  `Cache-Control: private, no-store`. That endpoint authorizes the viewer
  (session cookie or OAuth bearer token) on every request and answers `404`
  when they may not read the blob.

Access rules live in `Collavre::BlobAccess`: creative files follow the creative
(origin) read permission, comment images follow the comment's creative and the
comment's private flag, history snapshots follow the changed creative, and a
blob attached to nothing yet is readable by its uploader.

The stock ActiveStorage endpoints (`/rails/active_storage/blobs/*`,
`/representations/*`, `/direct_uploads`, `/disk/*`) are hardened by
`Collavre::ActiveStorageAccess`: the X-Origin-Secret check, the same
authorization, `private, no-store` responses, and authenticated direct uploads.

## CloudFront cache behavior

- **Path pattern:** `/public-assets/*`
- **Origin:** existing Rails origin
- **Viewer protocol policy:** Redirect HTTP to HTTPS
- **Allowed methods:** GET, HEAD
- **Cache policy:** Managed-CachingOptimized (honors the origin's `s-maxage`)
- **Origin request policy:** Managed-CORS-S3Origin (forward only the Host
  header; do not forward cookies or Authorization). Authorization happens on
  the redirect target, which goes through the default behavior.
- **Compress objects automatically:** Yes

`/rails/active_storage/*` must stay on a behavior that forwards cookies and
`Authorization` and does not cache (the default app behavior).

## Environment variables

- `PUBLIC_ASSETS_HOST` (optional) — CloudFront domain. When set, URLs returned
  by the MCP tools are absolute, and private-blob redirects point back at
  `DEFAULT_URL_HOST` so the browser sends its session cookie.
- `CLOUDFRONT_DISTRIBUTION_ID` (optional) — enables invalidation (below). The
  IAM principal used for S3 (or the instance role) needs
  `cloudfront:CreateInvalidation` on this distribution.

## Cache invalidation

`Collavre::CdnInvalidation` enqueues `CdnInvalidationJob` when:

- a blob that `/public-assets` served publicly is detached or purged —
  invalidates `/public-assets/blobs/<signed_id>/*`;
- a public share is removed or downgraded to `no_access` — invalidates
  `/public-assets/*` after the permission cache is updated.

Moving a creative out of a public subtree is not tracked; `s-maxage` bounds that
case to one day. Browser caches cannot be invalidated (`max-age` one hour).

## Rollout

Before this change every blob was served `public, max-age=31536000, immutable`.
After deploying, invalidate `/public-assets/*` once so CloudFront drops private
blobs it already cached. Copies already in browsers or other caches cannot be
recalled.
