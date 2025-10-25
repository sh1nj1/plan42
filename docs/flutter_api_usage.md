# Flutter Integration Guide for Collavre APIs

This guide walks through how to call the existing session (login), creative management, and comment-based chat endpoints from a Flutter application. It focuses on practical request/response details, CSRF/session handling, and quirks you should account for on the mobile client.

## 1. Environment and HTTP basics

* All endpoints below assume they are accessed from the primary Rails app (for example, `https://your.collavre.host`).
* The server issues a signed `session_id` cookie when you authenticate; you must attach it to every subsequent request so that the Rails middleware can recover the current user session.【F:app/controllers/concerns/authentication.rb†L16-L52】
* Rails keeps CSRF protection enabled, so non-GET requests must include a valid authenticity token. You can extract the token from any HTML response that renders `<%= csrf_meta_tags %>` (e.g., `GET /session/new` or `GET /`).【F:app/views/layouts/application.html.erb†L1-L45】
* All examples below use JSON requests (`Content-Type: application/json`). Rails automatically parses JSON bodies and exposes the parameters used in each controller.

### Sample Flutter HTTP client setup

```dart
final client = http.Client();
final baseUri = Uri.parse('https://your.collavre.host');

Future<String> fetchCsrfToken() async {
  final response = await client.get(baseUri.resolve('/session/new'));
  final csrfMeta = RegExp(r'name="csrf-token" content="([^"]+)"')
      .firstMatch(response.body);
  if (csrfMeta == null) {
    throw StateError('CSRF token not found');
  }
  return csrfMeta.group(1)!;
}
```

> **Tip:** Preserve the `Set-Cookie` headers returned by both the CSRF fetch and login requests. Packages such as [`http_cookie_jar`](https://pub.dev/packages/http_cookie_jar) or `dio`'s cookie interceptors simplify this.

## 2. Session (login) API

| Action | Method & Path | Parameters | Success Response |
| --- | --- | --- | --- |
| Fetch login form & CSRF token | `GET /session/new` | none | 200 HTML with hidden inputs + `<meta name="csrf-token">` | 
| Create session (email/password) | `POST /session` | `email`, `password`, optional `timezone`, optional `invite_token` | 302 redirect to home; `Set-Cookie: session_id=...` on success, 302 back to `/session/new` with error flash otherwise【F:app/controllers/sessions_controller.rb†L14-L31】 |
| Destroy session | `DELETE /session` | none | 302 redirect to `/session/new`, cookie cleared【F:app/controllers/sessions_controller.rb†L33-L37】 |

Implementation notes:

1. Fetch the CSRF token via `fetchCsrfToken()` and include it in a `X-CSRF-Token` header when you call `POST /session` or any mutating endpoint.
2. Rails expects flat parameters for email/password; when sending JSON you can use:
   ```json
   { "email": "user@example.com", "password": "secret", "timezone": "Asia/Seoul" }
   ```
3. A successful login returns a 302 and sets the signed `session_id` cookie. Treat any 302 whose `Location` header points to `/` as success.
4. When logging out, send the stored CSRF token along with the `DELETE /session` request to clear the cookie.【F:app/controllers/concerns/authentication.rb†L33-L52】

### Flutter snippet: perform login

```dart
Future<void> login(String email, String password, {String? timezone}) async {
  final token = await fetchCsrfToken();
  final response = await client.post(
    baseUri.resolve('/session'),
    headers: {
      'Content-Type': 'application/json',
      'X-CSRF-Token': token,
    },
    body: jsonEncode({
      'email': email,
      'password': password,
      if (timezone != null) 'timezone': timezone,
    }),
  );

  if (response.statusCode != 302) {
    throw StateError('Login failed: ${response.statusCode}\n${response.body}');
  }
}
```

## 3. Creative APIs

The `CreativesController` exposes JSON-friendly responses alongside HTML. Always request `.json` (either by suffix or `Accept: application/json`) to avoid HTML layouts.【F:app/controllers/creatives_controller.rb†L9-L77】【F:app/controllers/creatives_controller.rb†L89-L142】

### 3.1 List creatives

`GET /creatives.json`

Query parameters:

* `search`: full-text search across descriptions and comments.【F:app/services/creatives/index_query.rb†L33-L74】
* `comment=true`: return creatives that contain comments, sorted by recent activity.【F:app/services/creatives/index_query.rb†L34-L42】
* `id`: load children under a specific creative the current user can read.【F:app/services/creatives/index_query.rb†L44-L58】
* `tags[]`: optional tag filter; when present the response includes `overall_progress`.【F:app/services/creatives/index_query.rb†L76-L83】
* `simple=true`: compact payload with `id` and plain-text `description`.【F:app/controllers/creatives_controller.rb†L109-L118】

Response (standard mode):

```json
[
  { "id": 123, "description": "<p>HTML description</p>" },
  ...
]
```

### 3.2 Retrieve a single creative

`GET /creatives/:id.json`

Returns structural data plus the prompt the current user last saved for Gemini support.【F:app/controllers/creatives_controller.rb†L25-L67】

```json
{
  "id": 123,
  "description": "<p>HTML body</p>",
  "origin_id": null,
  "parent_id": null,
  "progress": 0.5,
  "depth": 2,
  "prompt": "Review the PR titled ..."
}
```

Optional query parameters:

* `root_id`: compute `depth` relative to a different ancestor.【F:app/controllers/creatives_controller.rb†L39-L52】

### 3.3 Create a creative

`POST /creatives.json`

Body shape:

```json
{
  "creative": {
    "description": "Plan next sprint",
    "parent_id": 123,          // optional
    "progress": 0.0,           // optional, 0.0–1.0 unless inheriting origin
    "origin_id": null,         // optional for linked creatives
    "sequence": 5              // optional ordering hint
  },
  "before_id": 456,            // optional: insert before sibling
  "after_id": 789,             // optional: insert after sibling
  "child_id": 987,             // optional: relink an existing child under new parent
  "tags": [1, 2]               // optional tag IDs to attach
}
```

Success returns `{ "id": <new_id> }`; validation errors return `{ "errors": ["..."] }` with HTTP 422.【F:app/controllers/creatives_controller.rb†L69-L107】

### 3.4 Update a creative

`PATCH /creatives/:id.json`

* Accepts the same `creative` payload as create. When the creative is a linked copy (`origin_id` present) only specific fields can change (`parent_id` update is handled separately).【F:app/controllers/creatives_controller.rb†L119-L147】
* Returns HTTP 200 with an empty body on success; JSON errors with 422 otherwise.

### 3.5 Delete a creative

`DELETE /creatives/:id`

* Requires the current user to have `:admin` permission on the creative; otherwise the request is redirected with an error flash.【F:app/controllers/creatives_controller.rb†L149-L196】
* Passing `delete_with_children=true` recursively removes all descendant creatives the user can administer.【F:app/controllers/creatives_controller.rb†L149-L196】
* The action currently returns an HTML redirect, so a Flutter client should treat HTTP 302 as success and optionally follow the redirect.

## 4. Comment (chat) APIs

Comments function as threaded chat messages tied to a creative. They are exposed through the nested `CommentsController` routes (`/creatives/:creative_id/comments`).【F:config/routes.rb†L30-L58】【F:app/controllers/comments_controller.rb†L1-L210】

> **Important:** Responses are rendered as HTML partials, because the existing web UI reuses them. JSON is only returned for error cases. Flutter clients can either render these fragments in a WebView, strip HTML tags, or extend the server with JSON views.

### 4.1 List comments

`GET /creatives/:creative_id/comments`

Query parameters:

* `page`: defaults to 1. Page 1 returns the entire comment list HTML (in reverse chronological order by default).【F:app/controllers/comments_controller.rb†L1-L30】
* `per_page`: defaults to 10 if omitted or invalid.【F:app/controllers/comments_controller.rb†L5-L18】

If you need participant info for avatar displays, call `GET /creatives/:creative_id/comments/participants.json` to receive a JSON array of user objects.【F:app/controllers/comments_controller.rb†L139-L168】

### 4.2 Create a comment (chat message)

`POST /creatives/:creative_id/comments`

Body:

```json
{
  "comment": {
    "content": "Here is my feedback",
    "private": false
  }
}
```

Notes:

* The current user must have at least `:feedback` permission on the creative or the controller returns `{ "error": "..." }` with HTTP 403.【F:app/controllers/comments_controller.rb†L31-L44】
* On success the response body is the rendered HTML for the new comment and the status is 201.【F:app/controllers/comments_controller.rb†L45-L63】
* Messages starting with `@gemini` will trigger the background AI responder job automatically.【F:app/controllers/comments_controller.rb†L54-L57】

### 4.3 Update or delete a comment

* `PATCH /creatives/:creative_id/comments/:id` updates content if the current user authored the comment; returns HTML partial or JSON errors.【F:app/controllers/comments_controller.rb†L65-L88】
* `DELETE /creatives/:creative_id/comments/:id` removes the comment when the caller is the author; returns HTTP 204 on success.【F:app/controllers/comments_controller.rb†L90-L104】

### 4.4 Special actions

* `POST /creatives/:creative_id/comments/:id/convert` converts a comment’s Markdown into new creatives and deletes the original comment.【F:app/controllers/comments_controller.rb†L106-L134】
* `POST /creatives/:creative_id/comments/:id/approve` and `PATCH /creatives/:creative_id/comments/:id/update_action` support approval workflows for assigned approvers; both return HTML snippets and JSON errors on failure.【F:app/controllers/comments_controller.rb†L136-L208】
* `POST /creatives/:creative_id/comments/move` moves selected comments to another creative, enforcing permission checks on both origin and target.【F:app/controllers/comments_controller.rb†L170-L208】

## 5. Handling HTML responses in Flutter

Because many comment endpoints (and some creative deletions) return HTML, consider the following approaches:

1. **Server-side extension:** Implement JSON views (e.g., `index.json.jbuilder`) so Flutter can consume structured data. This keeps the mobile client simple.
2. **HTML parsing:** Use packages like [`html`](https://pub.dev/packages/html) to convert the fragments into `Comment` models.
3. **Embedded WebViews:** Render the provided partials inside a WebView widget when exact parity with the web UI is required.

## 6. Testing your integration locally

* Spin up the Rails server with `bin/dev` or `rails server`, then point your Flutter app at `http://localhost:3000`.
* Seed data or create creatives through the web UI first to verify permissions.
* Use browser developer tools to watch the exact requests the existing frontend issues; replicate them in Flutter for quick parity.

By following the patterns above you can authenticate users, browse and mutate creative hierarchies, and participate in comment threads from a Flutter client with minimal backend changes.
