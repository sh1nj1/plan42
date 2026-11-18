require "test_helper"

module Collavre
  module Creatives
    class AttachmentsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @owner = users(:two)   # non-admin owner
        @other = users(:three) # non-admin, no share
        @app = Doorkeeper::Application.create!(
          name: "Test App", redirect_uri: "urn:ietf:wg:oauth:2.0:oob", owner: @owner, confidential: true, scopes: "public"
        )
      end

      def token_for(user)
        Doorkeeper::AccessToken.create!(application: @app, resource_owner_id: user.id, scopes: "public").token
      end

      def upload(content_type: "image/png", filename: "pic.png", bytes: "bytes")
        Rack::Test::UploadedFile.new(StringIO.new(bytes), content_type, original_filename: filename)
      end

      def quote_question_setup
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: @owner)
        agent = users(:ai_bot)
        Collavre::CreativeShare.create!(creative: creative, user: agent, shared_by: @owner, permission: :write)
        topic = Collavre::Topic.create!(creative: creative, user: @owner, name: "Doc chat")
        comment = Collavre::Comment.create!(creative: creative, topic: topic, user: @owner, content: "> x\n\nwhy?",
                                            quoted_creative: creative, quoted_text: "x", review_type: :question,
                                            skip_dispatch: true)
        task = Collavre::Task.create!(agent: agent, creative: creative, topic_id: topic.id, name: "Question",
                                      status: "running", trigger_comment_id: comment.id)
        [ creative, agent, task ]
      end

      def path_for(creative)
        Collavre::Engine.routes.url_helpers.creative_attachments_path(creative)
      end

      test "401 without bearer token" do
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: @owner)
        post path_for(creative), params: { file: upload }
        assert_response :unauthorized
      end

      test "403 without write permission" do
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: @owner)
        post path_for(creative),
             params: { file: upload },
             headers: { "Authorization" => "Bearer #{token_for(@other)}" }
        assert_response :forbidden
      end

      test "uploads an image, embeds <img>, attaches to creative.files" do
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: @owner)
        post path_for(creative),
             params: { file: upload(content_type: "image/png", filename: "pic.png") },
             headers: { "Authorization" => "Bearer #{token_for(@owner)}" }
        assert_response :success
        body = JSON.parse(response.body)
        assert body["signed_id"].present?
        assert_equal "pic.png", body["filename"]
        creative.reload
        assert_includes creative.description, "<img"
        assert_includes creative.description, body["signed_id"]
        assert_includes creative.files.map { |f| f.blob.signed_id }, body["signed_id"]
      end

      test "stores a bearer upload as a draft under review policy" do
        creative = Collavre::Creative.create!(
          description: "<p>x</p>", user: @owner,
          data: { "ai_write_policy" => "review" }
        )
        assert creative.ai_write_review?

        post path_for(creative),
             params: { file: upload(content_type: "image/png", filename: "proposal.png") },
             headers: { "Authorization" => "Bearer #{token_for(@owner)}" }

        assert_response :success
        body = JSON.parse(response.body)
        assert body["pending_review"], body.inspect
        assert_equal "<p>x</p>", creative.reload.description
        assert_empty creative.files
        draft = CreativeChangeSet.find(body.fetch("change_set_id"))
        assert_equal "mcp", draft.origin
        retained_blob = draft.creative_changes.sole.history_file_attachments.sole.blob

        applied = Creatives::ChangeSetApplyService.new(source: draft, user: @owner, mode: :draft).call

        assert_equal :applied, applied.status
        assert_equal retained_blob.id, creative.reload.files.blobs.sole.id
        assert_includes creative.description, retained_blob.signed_id
      end

      test "refuses an agent upload during a document-mode question turn" do
        creative, agent, task = quote_question_setup

        post path_for(creative), params: { file: upload }, headers: { "Authorization" => "Bearer #{token_for(agent)}" }

        assert_response :unprocessable_entity
        assert_equal I18n.t("collavre.comments.creative_quote.question_read_only"), JSON.parse(response.body)["error"]
        assert_equal "<p>x</p>", creative.reload.description
        assert_equal 0, ActiveStorage::Blob.where(filename: "pic.png").count
        assert task.reload.running?
      end

      test "an agent upload naming another active task is not blocked by a question turn" do
        creative, agent, = quote_question_setup
        plain = Collavre::Task.create!(agent: agent, creative: creative, name: "Plain", status: "running")

        post path_for(creative), params: { file: upload },
             headers: { "Authorization" => "Bearer #{token_for(agent)}", "X-Collavre-Task" => plain.id.to_s }

        assert_response :success
        assert_includes creative.reload.description, "<img"
      end

      test "uploads an mp4 and embeds <video controls>" do
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: @owner)
        post path_for(creative),
             params: { file: upload(content_type: "video/mp4", filename: "clip.mp4") },
             headers: { "Authorization" => "Bearer #{token_for(@owner)}" }
        assert_response :success
        creative.reload
        assert_includes creative.description, "<video"
        assert_includes creative.description, "controls"
      end

      test "sniffs content type when client sends octet-stream (CLI uploads)" do
        # The bundled `collavre attach` CLI always sends the multipart part as
        # application/octet-stream. The endpoint must sniff real PNG bytes back
        # to image/png so it embeds as <img>, not a generic download link.
        png_bytes = File.binread(Collavre::Engine.root.join("test/fixtures/files/small.png"))
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: @owner)
        post path_for(creative),
             params: { file: upload(content_type: "application/octet-stream", filename: "pic.png", bytes: png_bytes) },
             headers: { "Authorization" => "Bearer #{token_for(@owner)}" }
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal "image/png", body["content_type"]
        assert_includes creative.reload.description, "<img"
      end

      test "422 when no file param" do
        creative = Collavre::Creative.create!(description: "<p>x</p>", user: @owner)
        post path_for(creative),
             headers: { "Authorization" => "Bearer #{token_for(@owner)}" }
        assert_response :unprocessable_entity
      end

      test "upload to a linked creative attaches to the effective origin" do
        # Linked rows cannot change their own description; the upload must embed
        # into the origin (where description lives) instead of raising mid-request
        # (description_cannot_change_if_has_origin) and orphaning the blob.
        origin = Collavre::Creative.create!(description: "<p>origin</p>", user: @owner)
        linked = Collavre::Creative.create!(origin: origin, user: @owner)

        post path_for(linked),
             params: { file: upload(content_type: "image/png", filename: "pic.png") },
             headers: { "Authorization" => "Bearer #{token_for(@owner)}" }
        assert_response :success
        body = JSON.parse(response.body)

        origin.reload
        assert_includes origin.description, "<img"
        assert_includes origin.description, body["signed_id"]
        assert_includes origin.files.map { |f| f.blob.signed_id }, body["signed_id"]
        assert_not_includes linked.reload.description.to_s, body["signed_id"]
      end

      test "422 for a GitHub-synced creative and creates no orphan blob" do
        # GitHub-synced creatives reject description changes
        # (description_cannot_change_if_github_source), so embedding would raise
        # mid-request. The endpoint must reject BEFORE creating the blob so a
        # rejected upload leaves no orphaned ActiveStorage blob.
        creative = Collavre::Creative.create!(
          description: "<p>synced</p>", user: @owner,
          data: { "source" => { "type" => "github_markdown" } }
        )
        assert_no_difference -> { ActiveStorage::Blob.count } do
          post path_for(creative),
               params: { file: upload(content_type: "image/png", filename: "pic.png") },
               headers: { "Authorization" => "Bearer #{token_for(@owner)}" }
        end
        assert_response :unprocessable_entity
        assert_not_includes creative.reload.description.to_s, "<img"
      end
    end
  end
end
