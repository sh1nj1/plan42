require "test_helper"

module Collavre
  class Creative
    class DescribableTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
      end

      test "markdown_source setter normalizes CRLF and CR to LF" do
        creative = Creative.new(user: @user)

        creative.markdown_source = "a\r\nb\rc\nd"
        assert_equal "a\nb\nc\nd", creative.markdown_source
      end

      test "markdown_source setter leaves non-string values untouched" do
        creative = Creative.new(user: @user)

        creative.markdown_source = nil
        assert_nil creative.markdown_source
      end

      test "convert_markdown_to_html persists normalized markdown_source" do
        creative = Creative.new(user: @user, content_type_input: "markdown", markdown_source: "line1\r\nline2\r\n")
        creative.save!

        assert_equal "line1\nline2\n", creative.data["markdown_source"]
        assert_equal "markdown", creative.data["content_type"]
      end

      test "description-only update on markdown creative demotes to html" do
        Creative.create!(user: @user, content_type_input: "markdown", markdown_source: "# old")
        creative = Creative.last
        assert_equal "markdown", creative.data["content_type"]
        assert_equal "# old", creative.data["markdown_source"]

        creative.update!(description: "<h1>new from tool</h1>")
        creative.reload

        assert_nil creative.data["content_type"]
        assert_nil creative.data["markdown_source"]
        assert_includes creative.description, "new from tool"
      end

      test "non-description update on markdown creative preserves markdown metadata" do
        Creative.create!(user: @user, content_type_input: "markdown", markdown_source: "# keep")
        creative = Creative.last
        assert_equal "markdown", creative.data["content_type"]

        creative.update!(progress: 1.0)
        creative.reload

        assert_equal "markdown", creative.data["content_type"]
        assert_equal "# keep", creative.data["markdown_source"]
      end

      test "GFM task list checkboxes survive sanitization" do
        source = "- [ ] todo\n- [x] done\n"

        Creative.create!(user: @user, content_type_input: "markdown", markdown_source: source)
        creative = Creative.last

        assert_match %r{<input[^>]*type="checkbox"[^>]*disabled}, creative.description
        assert_match %r{<input[^>]*checked[^>]*}, creative.description
      end

      test "markdown_editor persists the authoring surface in data[editor]" do
        rich = Creative.create!(
          user: @user, content_type_input: "markdown", markdown_editor: "rich", markdown_source: "# hi"
        )
        assert_equal "rich", rich.data["editor"]

        source = Creative.create!(
          user: @user, content_type_input: "markdown", markdown_editor: "source", markdown_source: "# hi"
        )
        assert_equal "source", source.data["editor"]
      end

      test "markdown_editor defaults to source when absent" do
        creative = Creative.create!(user: @user, content_type_input: "markdown", markdown_source: "# hi")
        assert_equal "source", creative.data["editor"]
      end

      test "demoting markdown to html clears the editor preference" do
        creative = Creative.create!(
          user: @user, content_type_input: "markdown", markdown_editor: "rich", markdown_source: "# hi"
        )
        assert_equal "rich", creative.data["editor"]

        creative.update!(content_type_input: "html", description: "<p>plain</p>")
        creative.reload
        assert_nil creative.data["editor"]
      end

      test "color span survives sanitization in markdown mode" do
        source = '<span style="color: rgb(255, 0, 0)">red</span> and ' \
                 '<span style="background-color: #ffff00">hl</span>'
        Creative.create!(user: @user, content_type_input: "markdown", markdown_source: source)
        creative = Creative.last

        # Canonical markdown_source is preserved verbatim (sanitizer only touches
        # the rendered description).
        assert_equal source, creative.data["markdown_source"]
        # Rendered description keeps the colors (spacing is normalized by the CSS scrubber).
        assert_match(/color:\s*rgb\(255, 0, 0\)/, creative.description)
        assert_match(/background-color:\s*#ffff00/, creative.description)
        assert_includes creative.description, "red"
        assert_includes creative.description, "hl"
      end

      test "color span survives sanitization in html mode" do
        Creative.create!(user: @user, description: '<p><span style="color: #ff0000">hi</span></p>')
        creative = Creative.last

        assert_match(/color:\s*#ff0000/, creative.description)
        assert_includes creative.description, "hi"
      end

      test "non-color style declarations are scrubbed from spans" do
        Creative.create!(
          user: @user,
          description: '<p><span style="color: red; position: fixed; font-size: 99px">x</span></p>'
        )
        creative = Creative.last

        assert_match(/color:\s*red/, creative.description)
        refute_includes creative.description, "position"
        refute_includes creative.description, "font-size"
      end

      test "dangerous style values are dropped, leaving no style attribute" do
        Creative.create!(
          user: @user,
          description: '<p><span style="background: url(javascript:alert(1))">x</span></p>'
        )
        creative = Creative.last

        refute_includes creative.description, "javascript"
        refute_includes creative.description, "url("
        assert_includes creative.description, "x"
      end

      test "non-checkbox input tags are stripped from description" do
        Creative.create!(
          user: @user,
          description: %(<p>hi <input type="text" value="x"> <input type="submit"></p>)
        )
        creative = Creative.last

        refute_match %r{<input}, creative.description
        assert_includes creative.description, "hi"
      end

      test "inline data-URI image is rewritten to blob path in stored markdown_source" do
        pixel_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        data_uri = "data:image/png;base64,#{pixel_b64}"

        source = "before ![pixel](#{data_uri}) after"

        Creative.create!(user: @user, content_type_input: "markdown", markdown_source: source)
        creative = Creative.last

        stored = creative.data["markdown_source"]
        refute_includes stored, "data:image/png;base64,", "data URI should be rewritten out of stored markdown_source"
        assert_match %r{!\[pixel\]\(/rails/active_storage/blobs/[^)]+\)}, stored

        blob_count_after_first = ActiveStorage::Blob.count

        # Subsequent text edits around the (now blob-backed) image must not
        # re-import the data URI as a fresh blob.
        edited_source = stored.sub("before", "edited before")
        creative.update!(content_type_input: "markdown", markdown_source: edited_source)
        creative.reload

        assert_equal blob_count_after_first, ActiveStorage::Blob.count,
                     "editing surrounding text must not create new blobs"
        assert_includes creative.data["markdown_source"], "edited before"
      end

      # --- Attachment reconcile (creative.files derived from description HTML) ---

      def make_blob(filename: "a.png", content_type: "image/png")
        ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new("x"), filename: filename, content_type: content_type
        )
      end

      def asset_url(blob)
        "/public-assets/blobs/#{blob.signed_id}/#{blob.filename.sanitized}"
      end

      test "embedding a blob proxy URL in description attaches it on save" do
        creative = Creative.create!(description: "<p>hi</p>", user: @user)
        blob = make_blob
        creative.update!(description: %(<p>hi</p><img src="#{asset_url(blob)}" alt="a.png">))

        assert_includes creative.reload.files.map { |f| f.blob.signed_id }, blob.signed_id
      end

      test "removing the node detaches the blob on next save" do
        blob = make_blob
        creative = Creative.create!(description: %(<img src="#{asset_url(blob)}">), user: @user)
        assert_includes creative.reload.files.map { |f| f.blob.signed_id }, blob.signed_id

        creative.update!(description: "<p>gone</p>")

        refute_includes creative.reload.files.map { |f| f.blob.signed_id }, blob.signed_id
      end

      test "idempotent re-save does not churn attachments" do
        blob = make_blob
        creative = Creative.create!(description: %(<img src="#{asset_url(blob)}">), user: @user)
        before = creative.reload.files.map(&:id).sort

        creative.update!(progress: 0.5)

        assert_equal before, creative.reload.files.map(&:id).sort
      end

      test "malformed attachment HTML does not raise and save succeeds" do
        creative = Creative.create!(description: "<p>ok</p>", user: @user)
        assert_nothing_raised { creative.update!(description: "<p>x</p><img src=") }
      end

      test "detaching a blob still referenced by another creative does not purge it" do
        blob = make_blob
        shared = Creative.create!(description: %(<img src="#{asset_url(blob)}">), user: @user)
        other = Creative.create!(description: %(<img src="#{asset_url(blob)}">), user: @user)
        assert_includes shared.reload.files.map(&:blob_id), blob.id
        assert_includes other.reload.files.map(&:blob_id), blob.id

        # Run any enqueued purge so a (wrongly) purged blob would actually vanish.
        perform_enqueued_jobs { shared.update!(description: "<p>gone</p>") }

        refute_includes shared.reload.files.map(&:blob_id), blob.id
        assert ActiveStorage::Blob.exists?(blob.id), "blob referenced by another creative must survive"
        assert_includes other.reload.files.map(&:blob_id), blob.id
      end

      test "detaching a blob referenced nowhere else purges it" do
        blob = make_blob
        creative = Creative.create!(description: %(<img src="#{asset_url(blob)}">), user: @user)
        assert ActiveStorage::Blob.exists?(blob.id)

        perform_enqueued_jobs { creative.update!(description: "<p>gone</p>") }

        refute_includes creative.reload.files.map(&:blob_id), blob.id
        assert_not ActiveStorage::Blob.exists?(blob.id), "orphan blob should be purged"
      end

      test "saving a linked creative does not detach or purge its legacy files" do
        origin = Creative.create!(description: "<p>origin</p>", user: @user)
        linked = Creative.create!(user: @user, origin: origin)
        new_parent = Creative.create!(description: "<p>parent</p>", user: @user)
        blob = make_blob(filename: "legacy.png", content_type: "image/png")
        # Legacy attach landed directly on the linked row (its own description is blank).
        linked.files.attach(blob)
        assert_includes linked.reload.files.map(&:blob_id), blob.id

        # Moving the linked row triggers after_save; reconcile must not purge the blob.
        perform_enqueued_jobs { linked.update!(parent: new_parent) }

        assert_includes linked.reload.files.map(&:blob_id), blob.id
        assert ActiveStorage::Blob.exists?(blob.id), "linked-row legacy blob must survive a save"
      end

      test "rich-editor markdown upload attaches the referenced blob on save" do
        blob = make_blob
        # The rich (Lexical) editor is Markdown-canonical: an inserted image is
        # serialized as a raw <img> blob URL inside markdown_source.
        source = %(text\n\n<img src="#{asset_url(blob)}" alt="a.png">)
        creative = Creative.create!(
          user: @user, content_type_input: "markdown", markdown_editor: "rich", markdown_source: source
        )

        assert_includes creative.reload.files.map { |f| f.blob.signed_id }, blob.signed_id
      end

      test "markdown save does not detach an out-of-band attached blob" do
        # A blob attached directly (legacy / backfill) but never referenced in
        # the derived description must survive a normal markdown save:
        # AttachmentBackfill skips markdown creatives, so reconcile is their only
        # touch point and would otherwise purge a blob the user never removed.
        # The guard: only blobs that WERE referenced in the prior description get
        # detached, so an orphan that was never referenced is left alone.
        creative = Creative.create!(
          user: @user, content_type_input: "markdown", markdown_source: "# hi"
        )
        blob = make_blob
        creative.files.attach(blob)
        assert_includes creative.reload.files.map(&:blob_id), blob.id

        perform_enqueued_jobs do
          creative.update!(content_type_input: "markdown", markdown_source: "# hi\n\nmore")
        end

        assert_includes creative.reload.files.map(&:blob_id), blob.id
        assert ActiveStorage::Blob.exists?(blob.id)
      end

      test "rich-editor removing an embedded media node detaches its blob" do
        # The rich (Lexical) editor embeds an upload as a raw <img> blob URL in
        # markdown_source. When the user deletes that node, the blob is gone from
        # the re-rendered description but still attached — and the editor's purge
        # DELETE can't compensate while the attachment exists. It was referenced
        # in the prior description, so reconcile must detach (and purge) it.
        blob = make_blob
        with_image = %(text\n\n<img src="#{asset_url(blob)}" alt="a.png">)
        creative = Creative.create!(
          user: @user, content_type_input: "markdown", markdown_editor: "rich", markdown_source: with_image
        )
        assert_includes creative.reload.files.map(&:blob_id), blob.id

        perform_enqueued_jobs do
          creative.update!(content_type_input: "markdown", markdown_editor: "rich", markdown_source: "text")
        end

        refute_includes creative.reload.files.map(&:blob_id), blob.id
        refute ActiveStorage::Blob.exists?(blob.id)
      end

      # --- Sanitizer: media tags ---

      test "video tag with controls/src survives sanitization" do
        blob = make_blob(filename: "v.mp4", content_type: "video/mp4")
        creative = Creative.create!(description: %(<video controls src="#{asset_url(blob)}"></video>), user: @user)
        html = creative.reload.description
        assert_includes html, "<video"
        assert_includes html, "controls"
        assert_includes html, asset_url(blob)
      end

      test "script tag is still stripped" do
        creative = Creative.create!(description: "<p>x</p><script>alert(1)</script>", user: @user)
        refute_includes creative.reload.description, "<script"
      end

      # --- Backfill: embed orphan creative.files into description ---

      test "backfill embeds an attached-but-unreferenced blob into the description" do
        creative = Creative.create!(description: "<p>doc</p>", user: @user)
        blob = make_blob(filename: "ref.png", content_type: "image/png")
        # Simulate a legacy attachment: attached to creative.files but never
        # referenced in the description (attach on a persisted record does not
        # trigger the model save callbacks, so reconcile does not detach it).
        creative.files.attach(blob)
        refute_includes creative.reload.description, blob.signed_id
        assert_includes creative.files.map { |f| f.blob.signed_id }, blob.signed_id

        Collavre::AttachmentBackfill.embed_orphans!(creative)

        assert_includes creative.reload.description, blob.signed_id

        before = creative.reload.description
        Collavre::AttachmentBackfill.embed_orphans!(creative)
        assert_equal before, creative.reload.description
      end

      test "backfill skips markdown creatives and preserves their markdown source" do
        creative = Creative.create!(
          user: @user, content_type_input: "markdown", markdown_source: "# title\n\nbody"
        )
        blob = make_blob(filename: "ref.png", content_type: "image/png")
        creative.files.attach(blob)
        creative.reload
        assert_equal "markdown", creative.data["content_type"]

        Collavre::AttachmentBackfill.embed_orphans!(creative)
        creative.reload

        # Still markdown mode, source intact, description untouched (no HTML nodes appended).
        assert_equal "markdown", creative.data["content_type"]
        assert_equal "# title\n\nbody", creative.data["markdown_source"]
        refute_includes creative.description, blob.signed_id
      end
    end
  end
end
