# Creative Attachment Upload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let agents/editor attach files (svg/png/mp4/docs) to a Creative without server-local paths — bytes travel over a bearer multipart HTTP endpoint, get embedded inline in the description HTML (inline mp4 playback included), and `creative.files` is fully derived from that HTML.

**Architecture:** The description HTML is the single source of truth. A new bearer-only multipart endpoint creates an ActiveStorage blob, embeds the matching node (`<img>` / `<video controls>` / `<a download>`) into the Creative's description, and saves. On every save, a reconcile step syncs `creative.files` to exactly the blobs referenced in the HTML. A backfill migration embeds existing orphan `creative.files` into their description HTML before derivation-driven detach goes live. The Lexical editor's existing DirectUpload path converges into the same `creative.files` inventory via the same reconcile.

**Tech Stack:** Rails 8 engine (`collavre`), ActiveStorage, Doorkeeper bearer (via `lib/mcp_oauth_middleware.rb`), Lexical (React/JSX), Node.js CLI (`skills/collavre/scripts/collavre`), Minitest.

---

## File Structure

**Create:**
- `engines/collavre/app/controllers/collavre/creatives/attachments_controller.rb` — bearer multipart upload + server-side embed.
- `engines/collavre/app/javascript/lib/lexical/video_node.jsx` — Lexical DecoratorNode for inline `<video controls>`.
- `engines/collavre/db/migrate/YYYYMMDDHHMMSS_backfill_creative_files_into_description.rb` — embed orphan `creative.files` into description HTML.
- `engines/collavre/test/controllers/collavre/creatives/attachments_controller_test.rb`
- `engines/collavre/test/models/collavre/creative/reconcile_attachments_test.rb`
- `engines/collavre/test/migrations/backfill_creative_files_into_description_test.rb` (or a model-level test exercising the migration's embed helper)

**Modify:**
- `engines/collavre/app/models/collavre/creative/describable.rb` — add `reconcile_description_attachments` (after_save), extend sanitizer allowlist for `<video>`/`<source>`, extract a shared `attachment_node_html(blob)` helper.
- `engines/collavre/config/routes.rb` — nested `resources :attachments, only: [:create]` under `resources :creatives`.
- `engines/collavre/app/javascript/components/InlineLexicalEditor.jsx` — register `VideoNode`.
- `engines/collavre/app/javascript/components/plugins/image_upload_plugin.jsx` — route `video/*` → VideoNode.
- `engines/collavre/app/services/collavre/tools/creative_attach_files_service.rb` — retire `file_paths`/`MCP_UPLOAD_ROOT`; accept inline text content.
- `skills/collavre/scripts/collavre` — add `attach` subcommand (multipart POST).
- `engines/collavre/test/services/collavre/tools/creative_attach_files_service_test.rb` — rewrite for inline text.

---

## Shared HTML helper (defined in Task 1, used by Tasks 4, 6)

`attachment_node_html(blob)` returns the embed HTML string for a blob, branching on content type. The proxy path it emits MUST match what `extract_signed_ids_from_description` scans (`/rails/active_storage/blobs/...`) and what the sanitizer allows.

```ruby
# Collavre::Creative::Describable (private)
def attachment_node_html(blob)
  url = "/public-assets/blobs/#{blob.signed_id}/#{blob.filename.sanitized}"
  name = ERB::Util.html_escape(blob.filename.to_s)
  if blob.content_type.to_s.start_with?("image/")
    %(<img src="#{url}" alt="#{name}">)
  elsif blob.content_type.to_s.start_with?("video/")
    %(<video controls src="#{url}"></video>)
  else
    %(<a href="#{url}" download="#{name}" data-filesize="#{blob.byte_size}">#{name}</a>)
  end
end
```

> NOTE on extraction: `extract_signed_ids_from_description` scans `/rails/active_storage/blobs/...`, but `public_asset_url` and the helper above emit `/public-assets/blobs/<signed_id>/...`. The reconcile step (Task 1) MUST extend extraction to also match `/public-assets/blobs/<signed_id>/`. This is verified-critical: without it, embedded nodes are never reconciled into `creative.files`.

---

## Task 1: Reconcile `creative.files` from description HTML on save

**Files:**
- Modify: `engines/collavre/app/models/collavre/creative/describable.rb`
- Test: `engines/collavre/test/models/collavre/creative/reconcile_attachments_test.rb`

- [ ] **Step 1: Write failing test — embedded image is attached on save**

```ruby
require "test_helper"

module Collavre
  class Creative
    class ReconcileAttachmentsTest < ActiveSupport::TestCase
      def make_blob(filename: "a.png", content_type: "image/png")
        ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new("x"), filename: filename, content_type: content_type
        )
      end

      test "embedding a blob proxy URL in description attaches it to creative.files on save" do
        user = collavre_users(:one)
        creative = Collavre::Creative.create!(description: "<p>hi</p>", user: user)
        blob = make_blob
        url = "/public-assets/blobs/#{blob.signed_id}/#{blob.filename.sanitized}"

        creative.update!(description: %(<p>hi</p><img src="#{url}" alt="a.png">))

        assert_includes creative.reload.files.map { |f| f.blob.signed_id }, blob.signed_id
      end

      test "removing the node detaches the blob on next save" do
        user = collavre_users(:one)
        blob = make_blob
        url = "/public-assets/blobs/#{blob.signed_id}/#{blob.filename.sanitized}"
        creative = Collavre::Creative.create!(description: %(<img src="#{url}">), user: user)
        assert_includes creative.reload.files.map { |f| f.blob.signed_id }, blob.signed_id

        creative.update!(description: "<p>gone</p>")

        refute_includes creative.reload.files.map { |f| f.blob.signed_id }, blob.signed_id
      end

      test "idempotent re-save does not churn attachments" do
        user = collavre_users(:one)
        blob = make_blob
        url = "/public-assets/blobs/#{blob.signed_id}/#{blob.filename.sanitized}"
        creative = Collavre::Creative.create!(description: %(<img src="#{url}">), user: user)
        before = creative.reload.files.map { |f| f.id }.sort

        creative.update!(progress: 0.5)

        assert_equal before, creative.reload.files.map { |f| f.id }.sort
      end

      test "malformed HTML does not raise and save succeeds" do
        user = collavre_users(:one)
        creative = Collavre::Creative.create!(description: "<p>ok</p>", user: user)
        assert_nothing_raised { creative.update!(description: "<img src=") }
      end
    end
  end
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd ~/project/soonoh/plan42 && bin/rails test engines/collavre/test/models/collavre/creative/reconcile_attachments_test.rb`
Expected: FAIL (blob not attached — no reconcile yet). Confirm the fixture name `collavre_users(:one)` resolves; if not, adjust to the engine's actual user fixture/factory before proceeding.

- [ ] **Step 3: Extend extraction + add reconcile in describable.rb**

In `included do`, add after the existing `after_destroy_commit`:

```ruby
after_save :reconcile_description_attachments
```

Extend `extract_signed_ids_from_description` to also scan the public-assets path:

```ruby
def extract_signed_ids_from_description
  return [] if description.blank?

  html = description.to_s
  ids = html.scan(%r{/rails/active_storage/blobs/(?:redirect|proxy)/([^/?#]+)}).flatten
  ids += html.scan(%r{/rails/active_storage/blobs/([^/?#]+)}).flatten
  ids += html.scan(%r{/public-assets/blobs/([^/?#]+)}).flatten
  ids.uniq
end
```

Add the reconcile method (private):

```ruby
# Description HTML is the source of truth for attachments. After each save,
# make creative.files exactly match the blobs referenced in the description:
# attach referenced-but-unattached blobs, detach attached-but-unreferenced ones.
# Must never raise during save — malformed HTML yields [] and a no-op.
def reconcile_description_attachments
  referenced = extract_signed_ids_from_description.filter_map do |sid|
    ActiveStorage::Blob.find_signed(sid)
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    nil
  end
  referenced_ids = referenced.map(&:id).to_set

  current = files.includes(:blob).to_a
  current_blob_ids = current.map { |a| a.blob_id }.to_set

  to_attach = referenced.reject { |b| current_blob_ids.include?(b.id) }
  to_detach = current.reject { |a| referenced_ids.include?(a.blob_id) }

  return if to_attach.empty? && to_detach.empty?

  to_attach.each { |blob| files.attach(blob) }
  to_detach.each(&:purge_later)
rescue StandardError => e
  Rails.logger.error("Creative##{id}: reconcile_description_attachments failed: #{e.message}")
end
```

Also add the shared `attachment_node_html(blob)` helper (private) from the "Shared HTML helper" section above (Tasks 4 and 6 reuse it).

- [ ] **Step 4: Run, verify pass**

Run: `cd ~/project/soonoh/plan42 && bin/rails test engines/collavre/test/models/collavre/creative/reconcile_attachments_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd ~/project/soonoh/plan42-worktree221
git add engines/collavre/app/models/collavre/creative/describable.rb \
        engines/collavre/test/models/collavre/creative/reconcile_attachments_test.rb
git commit -m "feat(collavre): derive creative.files from description HTML on save"
```

---

## Task 2: Extend sanitizer allowlist for `<video>`/`<source>`

**Files:**
- Modify: `engines/collavre/app/models/collavre/creative/describable.rb:83-106` (`sanitize_description_html`)
- Test: `engines/collavre/test/models/collavre/creative/reconcile_attachments_test.rb` (append)

- [ ] **Step 1: Write failing test — `<video controls>` survives sanitize**

```ruby
test "video tag with controls/src survives sanitization" do
  user = collavre_users(:one)
  blob = make_blob(filename: "v.mp4", content_type: "video/mp4")
  url = "/public-assets/blobs/#{blob.signed_id}/#{blob.filename.sanitized}"
  creative = Collavre::Creative.create!(
    description: %(<video controls src="#{url}"></video>), user: user
  )
  html = creative.reload.description
  assert_includes html, "<video"
  assert_includes html, "controls"
  assert_includes html, url
end

test "script tag is still stripped" do
  user = collavre_users(:one)
  creative = Collavre::Creative.create!(description: "<p>x</p><script>alert(1)</script>", user: user)
  refute_includes creative.reload.description, "<script"
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd ~/project/soonoh/plan42 && bin/rails test engines/collavre/test/models/collavre/creative/reconcile_attachments_test.rb -n /video_tag/`
Expected: FAIL (`<video>` stripped).

- [ ] **Step 3: Extend the allowlist**

In `sanitize_description_html`, add media tags/attrs:

```ruby
def sanitize_description_html
  table_tags = %w[table thead tbody tfoot tr th td]
  table_attrs = %w[colspan rowspan]
  attachment_attrs = %w[download data-filesize]
  task_list_attrs = %w[type disabled checked]
  media_tags = %w[video source]
  media_attrs = %w[controls src preload width height poster]

  scrubbed = Loofah.fragment(description.to_s)
  scrubbed.css("input").each do |node|
    unless node["type"] == "checkbox" && node.has_attribute?("disabled")
      node.remove
    end
  end

  self.description = ActionController::Base.helpers.sanitize(
    scrubbed.to_html,
    tags: Rails::HTML5::SafeListSanitizer.allowed_tags.to_a + table_tags + media_tags + %w[input],
    attributes: Rails::HTML5::SafeListSanitizer.allowed_attributes.to_a + table_attrs + attachment_attrs + task_list_attrs + media_attrs + %w[data-lexical]
  )
end
```

- [ ] **Step 4: Run, verify pass**

Run: `cd ~/project/soonoh/plan42 && bin/rails test engines/collavre/test/models/collavre/creative/reconcile_attachments_test.rb`
Expected: PASS (all reconcile + sanitizer tests).

- [ ] **Step 5: Commit**

```bash
cd ~/project/soonoh/plan42-worktree221
git add engines/collavre/app/models/collavre/creative/describable.rb \
        engines/collavre/test/models/collavre/creative/reconcile_attachments_test.rb
git commit -m "feat(collavre): allow <video>/<source> in description sanitizer"
```

---

## Task 3: Bearer multipart upload endpoint (server-side embed)

**Files:**
- Create: `engines/collavre/app/controllers/collavre/creatives/attachments_controller.rb`
- Modify: `engines/collavre/config/routes.rb:60` (nest under `resources :creatives`)
- Test: `engines/collavre/test/controllers/collavre/creatives/attachments_controller_test.rb`

- [ ] **Step 1: Add the nested route**

In `routes.rb`, inside `resources :creatives do`, add near the other nested resources:

```ruby
namespace :creatives do
end
resources :creatives do
  resources :attachments, only: [ :create ], module: :creatives
  # ...existing nested resources...
```

Concretely: add this single line just after `resources :creatives do` opens (alongside `creative_shares`):

```ruby
    resources :attachments, only: [ :create ], module: :creatives
```

This yields `POST /creatives/:creative_id/attachments` → `Collavre::Creatives::AttachmentsController#create`.

- [ ] **Step 2: Write failing controller test**

```ruby
require "test_helper"

module Collavre
  module Creatives
    class AttachmentsControllerTest < ActionDispatch::IntegrationTest
      include Engine.routes.url_helpers

      def bearer_token_for(user)
        app = Doorkeeper::Application.create!(name: "test", redirect_uri: "urn:ietf:wg:oauth:2.0:oob")
        Doorkeeper::AccessToken.create!(application: app, resource_owner_id: user.id, scopes: "").token
      end

      def upload(content_type: "image/png", filename: "pic.png")
        Rack::Test::UploadedFile.new(StringIO.new("bytes"), content_type, original_filename: filename)
      end

      test "401 without bearer token" do
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: collavre_users(:one))
        post collavre.creative_attachments_path(creative), params: { file: upload }
        assert_response :unauthorized
      end

      test "403 without write permission" do
        owner = collavre_users(:one)
        other = collavre_users(:two)
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: owner)
        token = bearer_token_for(other)
        post collavre.creative_attachments_path(creative),
             params: { file: upload },
             headers: { "Authorization" => "Bearer #{token}" }
        assert_response :forbidden
      end

      test "uploads an image, embeds <img>, attaches to creative.files" do
        user = collavre_users(:one)
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: user)
        token = bearer_token_for(user)
        post collavre.creative_attachments_path(creative),
             params: { file: upload(content_type: "image/png", filename: "pic.png") },
             headers: { "Authorization" => "Bearer #{token}" }
        assert_response :success
        body = JSON.parse(response.body)
        assert body["signed_id"].present?
        assert_equal "pic.png", body["filename"]
        assert_includes creative.reload.description, "<img"
        assert_includes creative.reload.description, body["signed_id"]
        assert_includes creative.files.map { |f| f.blob.signed_id }, body["signed_id"]
      end

      test "uploads an mp4 and embeds <video controls>" do
        user = collavre_users(:one)
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: user)
        token = bearer_token_for(user)
        post collavre.creative_attachments_path(creative),
             params: { file: upload(content_type: "video/mp4", filename: "clip.mp4") },
             headers: { "Authorization" => "Bearer #{token}" }
        assert_response :success
        assert_includes creative.reload.description, "<video"
        assert_includes creative.reload.description, "controls"
      end

      test "422 when no file param" do
        user = collavre_users(:one)
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: user)
        token = bearer_token_for(user)
        post collavre.creative_attachments_path(creative),
             headers: { "Authorization" => "Bearer #{token}" }
        assert_response :unprocessable_entity
      end
    end
  end
end
```

- [ ] **Step 3: Run, verify it fails**

Run: `cd ~/project/soonoh/plan42 && bin/rails test engines/collavre/test/controllers/collavre/creatives/attachments_controller_test.rb`
Expected: FAIL (controller/route missing). If `bearer_token_for` helper shape is wrong for this app's Doorkeeper setup, inspect `lib/mcp_oauth_middleware.rb` + an existing MCP request test and align before continuing.

- [ ] **Step 4: Implement the controller**

```ruby
module Collavre
  module Creatives
    class AttachmentsController < ApplicationController
      include Collavre::PublicAssetsHelper

      # Bearer-only (no cookie/session). Doorkeeper bearer is resolved to
      # Current.user by lib/mcp_oauth_middleware.rb before the controller runs.
      skip_forgery_protection

      def create
        return render(json: { error: "Unauthorized" }, status: :unauthorized) unless Current.user

        creative = Collavre::Creative.find_by(id: params[:creative_id])
        return render(json: { error: "Creative not found" }, status: :not_found) unless creative

        unless creative.has_permission?(Current.user, :write)
          return render(json: { error: "No write permission" }, status: :forbidden)
        end

        file = params[:file]
        return render(json: { error: "No file" }, status: :unprocessable_entity) unless file.respond_to?(:read)

        blob = ActiveStorage::Blob.create_and_upload!(
          io: file.to_io,
          filename: file.original_filename,
          content_type: file.content_type.presence || Marcel::MimeType.for(file.to_io, name: file.original_filename)
        )

        # Embed the node into the description; after_save reconcile attaches it.
        creative.embed_attachment_blob!(blob)

        render json: {
          signed_id: blob.signed_id,
          filename: blob.filename.to_s,
          content_type: blob.content_type,
          byte_size: blob.byte_size,
          url: public_asset_url(blob)
        }
      end
    end
  end
end
```

Add the public embed method to `describable.rb` (it appends the node HTML and saves; reconcile attaches):

```ruby
# Append an attachment node for `blob` to the description and save.
# after_save reconcile picks up the new signed_id and attaches the blob.
def embed_attachment_blob!(blob)
  node = send(:attachment_node_html, blob)
  new_html = "#{description}#{node}"
  # Markdown-mode creatives derive description from markdown_source; demote to
  # HTML so the embedded node is the persisted truth (sanitizer keeps it).
  if data&.dig("content_type") == "markdown"
    self.content_type_input = "html"
  end
  update!(description: new_html)
end
```

> NOTE: `attachment_node_html` is private; `embed_attachment_blob!` calls it via `send`. If preferred, make `attachment_node_html` non-private — either is fine.

- [ ] **Step 5: Run, verify pass**

Run: `cd ~/project/soonoh/plan42 && bin/rails test engines/collavre/test/controllers/collavre/creatives/attachments_controller_test.rb`
Expected: PASS (5 tests). Then run the model tests again to confirm no regression.

- [ ] **Step 6: Commit**

```bash
cd ~/project/soonoh/plan42-worktree221
git add engines/collavre/app/controllers/collavre/creatives/attachments_controller.rb \
        engines/collavre/app/models/collavre/creative/describable.rb \
        engines/collavre/config/routes.rb \
        engines/collavre/test/controllers/collavre/creatives/attachments_controller_test.rb
git commit -m "feat(collavre): bearer multipart attachment upload endpoint with HTML embed"
```

---

## Task 4: VideoNode + editor registration + upload routing (frontend)

**Files:**
- Create: `engines/collavre/app/javascript/lib/lexical/video_node.jsx`
- Modify: `engines/collavre/app/javascript/components/InlineLexicalEditor.jsx:49-50,1001-1003`
- Modify: `engines/collavre/app/javascript/components/plugins/image_upload_plugin.jsx`

- [ ] **Step 1: Create `video_node.jsx`** (mirrors AttachmentNode shape; DecoratorNode → `<video controls>`)

```jsx
import {
    $applyNodeReplacement,
    DecoratorNode,
} from "lexical"

export class VideoNode extends DecoratorNode {
    __src
    __filename

    static getType() {
        return "video"
    }

    static clone(node) {
        return new VideoNode(node.__src, node.__filename, node.__key)
    }

    static importJSON(serializedNode) {
        const { src, filename } = serializedNode
        return $createVideoNode({ src, filename })
    }

    exportDOM() {
        const element = document.createElement("video")
        element.setAttribute("src", this.__src)
        element.setAttribute("controls", "")
        return { element }
    }

    static importDOM() {
        return {
            video: () => ({ conversion: convertVideoElement, priority: 1 }),
        }
    }

    constructor(src, filename, key) {
        super(key)
        this.__src = src
        this.__filename = filename
    }

    exportJSON() {
        return {
            src: this.getSrc(),
            filename: this.__filename,
            type: "video",
            version: 1,
        }
    }

    createDOM(config) {
        const span = document.createElement("span")
        const className = config.theme?.video
        if (className !== undefined) span.className = className
        return span
    }

    updateDOM() {
        return false
    }

    getSrc() {
        return this.__src
    }

    decorate() {
        return (
            <video
                src={this.__src}
                controls
                style={{ maxWidth: "100%", borderRadius: "4px" }}
            />
        )
    }
}

function convertVideoElement(domNode) {
    if (domNode instanceof HTMLVideoElement) {
        const src = domNode.getAttribute("src")
        if (!src) return null
        return { node: $createVideoNode({ src, filename: null }) }
    }
    return null
}

export function $createVideoNode({ src, filename }) {
    return $applyNodeReplacement(new VideoNode(src, filename))
}

export function $isVideoNode(node) {
    return node instanceof VideoNode
}
```

- [ ] **Step 2: Register in `InlineLexicalEditor.jsx`**

After line 50 add:
```jsx
import { VideoNode } from "../lib/lexical/video_node"
```
In the `nodes:` array (after `AttachmentNode` at ~line 1002) add `VideoNode`:
```jsx
        ImageNode,
        AttachmentNode,
        VideoNode
```

- [ ] **Step 3: Route `video/*` in `image_upload_plugin.jsx`**

Add import:
```jsx
import { $createVideoNode } from "../../lib/lexical/video_node"
```
Add a helper next to `isImageFile`:
```jsx
function isVideoFile(file) {
    if (!file) return false
    if (file.type) return /^video\//i.test(file.type)
    return /\.(mp4|webm|mov|m4v)$/i.test(file.name || "")
}
```
In `startDirectUpload`, replace the `if (isImage) {...} else {...}` node-creation block with:
```jsx
                    if (isImage) {
                        node = $createImageNode({
                            src: url,
                            altText: attributes.filename,
                            maxWidth: 800
                        })
                    } else if (isVideoFile(file)) {
                        node = $createVideoNode({
                            src: url,
                            filename: attributes.filename
                        })
                    } else {
                        node = $createAttachmentNode({
                            src: url,
                            filename: attributes.filename,
                            filesize: file.size
                        })
                    }
```
Compute `const isImage = isImageFile(file)` already exists; leave as-is.

- [ ] **Step 4: Build the JS bundle to verify it compiles**

Run: `cd ~/project/soonoh/plan42 && yarn build` (or the project's JS build — check `package.json` scripts; likely `bin/rails javascript:build` or `yarn build`).
Expected: build succeeds, no import/syntax errors. Inspecting the built output is enough; full browser verification is a manual QA step (headless Chromium can't reliably play media).

- [ ] **Step 5: Commit**

```bash
cd ~/project/soonoh/plan42-worktree221
git add engines/collavre/app/javascript/lib/lexical/video_node.jsx \
        engines/collavre/app/javascript/components/InlineLexicalEditor.jsx \
        engines/collavre/app/javascript/components/plugins/image_upload_plugin.jsx
git commit -m "feat(collavre): VideoNode for inline mp4 playback in Lexical editor"
```

---

## Task 5: CLI `attach` subcommand (multipart POST)

**Files:**
- Modify: `skills/collavre/scripts/collavre` — add `attach` to `commands`, document in help.

- [ ] **Step 1: Add a multipart POST helper + `attach` command**

Add near the top (after imports), a small multipart helper using Node's built-in `http`/`https`:

```js
// --- Multipart upload (bearer) to the Collavre web app ---
function postMultipartFile(baseUrl, token, creativeId, filePath) {
  return new Promise((resolve, reject) => {
    const fileName = path.basename(filePath);
    const fileBuf = fs.readFileSync(filePath);
    const boundary = "----collavre" + Buffer.from(fileName + fileBuf.length).toString("hex").slice(0, 16);
    const head = Buffer.from(
      `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="file"; filename="${fileName}"\r\n` +
      `Content-Type: application/octet-stream\r\n\r\n`
    );
    const tail = Buffer.from(`\r\n--${boundary}--\r\n`);
    const body = Buffer.concat([head, fileBuf, tail]);

    const url = new URL(`${baseUrl.replace(/\/+$/, "")}/creatives/${creativeId}/attachments`);
    const mod = url.protocol === "https:" ? https : http;
    const req = mod.request(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": `multipart/form-data; boundary=${boundary}`,
        "Content-Length": body.length,
      },
    });
    req.on("response", (res) => {
      let data = "";
      res.on("data", (c) => (data += c));
      res.on("end", () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          try { resolve(JSON.parse(data)); } catch { resolve({ raw: data }); }
        } else {
          reject(new Error(`HTTP ${res.statusCode}: ${data}`));
        }
      });
    });
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}
```

Add the command to the `commands` object:

```js
  async attach(argv) {
    const { args } = parseArgs(argv);
    const creativeId = parseInt(args.creative);
    const files = [].concat(args.file || []);
    if (!creativeId || files.length === 0 || files[0] === true) {
      console.error("Usage: collavre attach --creative <id> --file <path> [--file <path> ...]");
      process.exit(1);
    }
    const config = loadConfig();
    if (!config.url || !config.token) {
      console.error("Not configured. Run: collavre auth --url <url> --token <token>");
      process.exit(1);
    }
    // config.url is the MCP base (…/ for /mcp/sse). The web app root is the same origin.
    const webBase = new URL(config.url).origin;
    for (const f of files) {
      const result = await postMultipartFile(webBase, config.token, creativeId, f);
      console.log(JSON.stringify(result, null, 2));
    }
  },
```

> NOTE: `parseArgs` collapses repeated `--file` flags to the last value (it assigns `args[key] = next`). To support multiple `--file`, either accept a single `--file` for v1 (simplest, matches the common case) OR enhance `parseArgs` to push repeated keys into an array. For v1, document single-file and treat `args.file` as one path: replace the `files` handling with `const files = args.file && args.file !== true ? [args.file] : []`.

- [ ] **Step 2: Update help text**

In the `auth`/help block and the top-level help, add:
```
  attach   --creative <id> --file <path>   Upload & embed a file (bearer multipart)
```

- [ ] **Step 3: Smoke test against the configured server**

Run:
```bash
echo "Hello World!" > /tmp/cli-attach-test.txt
node ~/project/soonoh/plan42-worktree221/skills/collavre/scripts/collavre attach --creative 13069 --file /tmp/cli-attach-test.txt
```
Expected: JSON with `signed_id`, `url`. Then `curl -sI "https://collavre.com<url-path>"` returns 200. (Use `collavre.com`, not the tailscale host — see memory.)

- [ ] **Step 4: Commit**

```bash
cd ~/project/soonoh/plan42-worktree221
git add skills/collavre/scripts/collavre
git commit -m "feat(collavre-cli): add attach command for bearer multipart file upload"
```

---

## Task 6: Backfill migration — embed orphan `creative.files` into description HTML

**Files:**
- Create: `engines/collavre/db/migrate/YYYYMMDDHHMMSS_backfill_creative_files_into_description.rb`
- Test: `engines/collavre/test/models/collavre/creative/reconcile_attachments_test.rb` (append a backfill-behavior test exercising the embed path), or a dedicated migration test.

- [ ] **Step 1: Write failing test — orphan file gets an embed node**

```ruby
test "backfill embeds an attached-but-unreferenced blob into the description" do
  user = collavre_users(:one)
  creative = Collavre::Creative.create!(description: "<p>doc</p>", user: user)
  blob = make_blob(filename: "ref.png", content_type: "image/png")
  # Attach WITHOUT referencing in HTML (simulates legacy MCP attach).
  creative.files.attach(blob)
  creative.save!
  refute_includes creative.reload.description, blob.signed_id

  Collavre::AttachmentBackfill.embed_orphans!(creative)

  assert_includes creative.reload.description, blob.signed_id
  # idempotent
  before = creative.reload.description
  Collavre::AttachmentBackfill.embed_orphans!(creative)
  assert_equal before, creative.reload.description
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd ~/project/soonoh/plan42 && bin/rails test engines/collavre/test/models/collavre/creative/reconcile_attachments_test.rb -n /backfill/`
Expected: FAIL (`Collavre::AttachmentBackfill` undefined).

- [ ] **Step 3: Implement the backfill helper + migration**

Create `engines/collavre/app/services/collavre/attachment_backfill.rb`:

```ruby
module Collavre
  module AttachmentBackfill
    module_function

    # For one creative, append embed nodes for any attached blob whose signed_id
    # is not already referenced in the description. Idempotent. Reuses the
    # creative's own node-HTML helper so output matches runtime embeds.
    def embed_orphans!(creative)
      referenced = creative.send(:extract_signed_ids_from_description).to_set
      orphans = creative.files.includes(:blob).reject do |att|
        referenced.include?(att.blob.signed_id)
      end
      return if orphans.empty?

      nodes = orphans.map { |att| creative.send(:attachment_node_html, att.blob) }.join
      new_html = "#{creative.description}#{nodes}"
      # Bypass reconcile-driven detach concerns: this only ADDS references for
      # blobs already attached, so reconcile on save is a no-op for them.
      creative.update_columns(description: creative.send(:sanitize_for_backfill, new_html))
    rescue StandardError => e
      Rails.logger.error("AttachmentBackfill: creative #{creative.id} failed: #{e.message}")
    end
  end
end
```

> Because `update_columns` skips callbacks (so sanitize/reconcile don't run), add a small `sanitize_for_backfill(html)` private method on the model that runs the same sanitizer used in `sanitize_description_html`, OR simply use `creative.update!(description: new_html)` to go through the normal save path (sanitizer + reconcile). **Prefer `update!`** for correctness — reconcile is a no-op since blobs are already attached, and the sanitizer keeps `<img>/<video>/<a>`. Replace the `update_columns(...)` line with:
> ```ruby
> creative.update!(description: new_html)
> ```
> and delete the `sanitize_for_backfill` reference.

Create the migration:

```ruby
class BackfillCreativeFilesIntoDescription < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    Collavre::Creative.reset_column_information
    Collavre::Creative.where.not(description: nil).find_each(batch_size: 200) do |creative|
      next if creative.files.blank?
      Collavre::AttachmentBackfill.embed_orphans!(creative)
    end
  end

  def down
    # No-op: embedding nodes is non-destructive and idempotent; we do not
    # remove embedded media on rollback.
  end
end
```

- [ ] **Step 4: Run, verify pass**

Run: `cd ~/project/soonoh/plan42 && bin/rails test engines/collavre/test/models/collavre/creative/reconcile_attachments_test.rb -n /backfill/`
Expected: PASS.

- [ ] **Step 5: Run the migration locally (dev DB) and confirm idempotency**

Run: `cd ~/project/soonoh/plan42 && bin/rails db:migrate` then `bin/rails db:migrate` again (or re-run by reverting). Expected: second run embeds nothing new.

- [ ] **Step 6: Commit**

```bash
cd ~/project/soonoh/plan42-worktree221
git add engines/collavre/app/services/collavre/attachment_backfill.rb \
        engines/collavre/db/migrate/*backfill_creative_files_into_description.rb \
        engines/collavre/test/models/collavre/creative/reconcile_attachments_test.rb
git commit -m "feat(collavre): backfill migration embedding orphan attachments into description"
```

---

## Task 7: Retire `file_paths` on MCP `creative_attach_files_service` (inline text)

**Files:**
- Modify: `engines/collavre/app/services/collavre/tools/creative_attach_files_service.rb`
- Test: `engines/collavre/test/services/collavre/tools/creative_attach_files_service_test.rb` (rewrite)

- [ ] **Step 1: Rewrite the test for inline text content**

```ruby
require "test_helper"

module Collavre
  module Tools
    class CreativeAttachFilesServiceTest < ActiveSupport::TestCase
      test "attaches inline text content and embeds a download link" do
        user = collavre_users(:one)
        Current.user = user
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: user)

        result = CreativeAttachFilesService.new.call(
          creative_id: creative.id,
          files: [ { "filename" => "notes.md", "content" => "# Hello", "content_type" => "text/markdown" } ]
        )

        assert result[:success]
        sid = result[:attachments].first[:signed_id]
        assert_includes creative.reload.description, sid
        assert_includes creative.files.map { |f| f.blob.signed_id }, sid
      ensure
        Current.user = nil
      end

      test "missing write permission returns error" do
        owner = collavre_users(:one)
        other = collavre_users(:two)
        Current.user = other
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: owner)
        result = CreativeAttachFilesService.new.call(
          creative_id: creative.id, files: [ { "filename" => "a.txt", "content" => "x" } ]
        )
        assert result[:error]
      ensure
        Current.user = nil
      end
    end
  end
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd ~/project/soonoh/plan42 && bin/rails test engines/collavre/test/services/collavre/tools/creative_attach_files_service_test.rb`
Expected: FAIL (still expects `file_paths`).

- [ ] **Step 3: Rewrite the service**

```ruby
module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CreativeAttachFilesService
    extend T::Sig
    extend ToolMeta
    include Collavre::PublicAssetsHelper

    tool_name "creative_attach_files_service"
    tool_description "Attach inline, agent-generated TEXT content (markdown, html, svg, plain text) to a Creative. The content is stored as an ActiveStorage blob, embedded into the Creative's description, and served via /public-assets URLs.\n\nFor BINARY files (png, mp4, pdf) the agent produced on disk, use the CLI `collavre attach --creative <id> --file <path>` instead — it uploads bytes over a bearer multipart HTTP endpoint.\n\nRequires :write permission on the target Creative."

    tool_param :creative_id, description: "ID of the Creative to attach content to.", required: true
    tool_param :files, description: "Array of { filename, content, content_type? }. `content` is the literal UTF-8 text to store (e.g. markdown/html/svg). content_type is inferred from the filename when omitted.", required: true

    sig { params(creative_id: Integer, files: T::Array[T::Hash[String, T.untyped]]).returns(T::Hash[Symbol, T.untyped]) }
    def call(creative_id:, files:)
      raise "Current.user is required" unless Current.user

      creative = Creative.find_by(id: creative_id)
      return { error: "Creative not found", id: creative_id } unless creative
      unless creative.has_permission?(Current.user, :write)
        return { error: "No write permission on Creative", id: creative_id }
      end
      return { error: "No files provided" } if files.blank?

      blobs = []
      files.each do |f|
        name = f["filename"].to_s
        content = f["content"].to_s
        return { error: "Each file needs a filename" } if name.blank?

        blobs << ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(content),
          filename: name,
          content_type: f["content_type"].presence || Marcel::MimeType.for(name: name) || "text/plain"
        )
      end

      blobs.each { |b| creative.embed_attachment_blob!(b) }

      {
        success: true,
        creative_id: creative.id,
        attachments: blobs.map { |b|
          { signed_id: b.signed_id, filename: b.filename.to_s, content_type: b.content_type, byte_size: b.byte_size, url: public_asset_url(b) }
        }
      }
    end
  end
end
end
```

> `embed_attachment_blob!` saves once per blob; acceptable for the small counts here. Removed: `file_paths`, `upload_root`, `path_under?`, all realpath/missing/outside logic, and the `MCP_UPLOAD_ROOT` integration setting usage.

- [ ] **Step 4: Run, verify pass**

Run: `cd ~/project/soonoh/plan42 && bin/rails test engines/collavre/test/services/collavre/tools/creative_attach_files_service_test.rb`
Expected: PASS.

- [ ] **Step 5: Grep for any other `MCP_UPLOAD_ROOT` / `upload_root` references and clean up**

Run: `cd ~/project/soonoh/plan42-worktree221 && grep -rn "mcp_upload_root\|MCP_UPLOAD_ROOT\|upload_root" engines/ lib/ config/ --include=*.rb`
Expected: no remaining references (remove from `env.template`, `IntegrationSettings` defaults, `config/deploy.yml`, `.kamal/secrets` if present — per the env-var rule in Collavre 개발 룰).

- [ ] **Step 6: Commit**

```bash
cd ~/project/soonoh/plan42-worktree221
git add engines/collavre/app/services/collavre/tools/creative_attach_files_service.rb \
        engines/collavre/test/services/collavre/tools/creative_attach_files_service_test.rb
git commit -m "feat(collavre): MCP attach tool takes inline text; binary moves to HTTP endpoint"
```

---

## Task 8: Full suite, i18n, rubocop, PR

- [ ] **Step 1: Run the engine test suite**

Run: `cd ~/project/soonoh/plan42 && bin/rails test` (host app runs all engines per Collavre 개발 룰). Expected: green.

- [ ] **Step 2: Rubocop**

Run: `cd ~/project/soonoh/plan42-worktree221 && bundle exec rubocop engines/collavre/app engines/collavre/db engines/collavre/test`
Expected: no offenses (fix any).

- [ ] **Step 3: i18n check** — any new user-facing strings (controller error messages) should be `en` + `ko` per the rules. The controller returns JSON error strings to API clients (agents), not end-user UI; keep them plain English (consistent with sibling MCP services which return raw English errors). No locale keys required. Confirm no `t(...)` placeholder was left untranslated.

- [ ] **Step 4: Push + open PR** (English title/body, Conventional Commits)

```bash
cd ~/project/soonoh/plan42-worktree221
git push -u origin feat/creative-attachment-upload
gh pr create --title "feat(collavre): HTML-derived attachment upload (bearer endpoint + inline video)" \
  --body "$(cat <<'EOF'
## Summary
- New bearer multipart endpoint `POST /creatives/:id/attachments` uploads bytes and embeds the node into the description (no server-local paths).
- `creative.files` is now fully derived from the description HTML via after_save reconcile.
- Inline mp4 playback: new Lexical `VideoNode` + sanitizer allows `<video>/<source>`.
- Backfill migration embeds existing orphan `creative.files` into their description HTML (idempotent, no-op down).
- MCP `creative_attach_files_service` retires `file_paths`/`MCP_UPLOAD_ROOT`; now takes inline text content.
- CLI `collavre attach --creative <id> --file <path>`.

## Review focus / risk
- **Backfill migration rewrites stored description HTML.** Idempotent + non-destructive; must run before any reconcile-driven detach matters in prod.
- Sanitizer allowlist widened for media tags — scoped to `<video>/<source>` + controls/src/preload/width/height/poster.

Closes Collavre creative 13069.
EOF
)"
```

- [ ] **Step 5: Register PR monitoring** via the `pr_monitor` MCP tool (per trigger 10534), then move creative 13069 under "리뷰" (id 10535).

---

## Self-Review

**Spec coverage:** §1 upload endpoint → Task 3. §2 CLI → Task 5. §3 VideoNode+sanitizer → Tasks 2,4. §4 reconcile → Task 1. §5 backfill → Task 6. §6 MCP retire → Task 7. Non-goal (absolute URL) untouched (already config-driven). All covered.

**Type/name consistency:** `attachment_node_html(blob)` defined in Task 1, reused in Tasks 3 (`embed_attachment_blob!`), 6 (`AttachmentBackfill`). `embed_attachment_blob!` defined in Task 3, reused in Task 7. `extract_signed_ids_from_description` extended in Task 1, reused in Tasks 1,6. `$createVideoNode`/`VideoNode` defined Task 4, registered same task. Consistent.

**Known open items to resolve at execution (not placeholders):**
- Exact user fixture/factory name (`collavre_users(:one)`) — verify before Task 1.
- Doorkeeper test-token construction — align with existing MCP request specs before Task 3.
- JS build command — confirm from `package.json` before Task 4.
- `parseArgs` multi-`--file` — v1 single file (documented in Task 5).
