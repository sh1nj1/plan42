require "test_helper"

module Collavre
  module Creatives
    class FileDropsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @owner = users(:two)
        sign_in_as(@owner, password: "password")
        @parent = Creative.create!(description: "Parent", user: @owner)
        @target = Creative.create!(description: "Target", parent: @parent, user: @owner)
      end

      test "center appends multiple attachments without creating a creative" do
        assert_no_difference "Creative.count" do
          drop("child", files: [ upload("image/png", "pic.png"), upload("video/mp4", "clip.mp4"), upload ])
        end
        assert_response :success
        assert_equal @target.id, response.parsed_body["id"]
        assert_equal 3, @target.reload.files.count
        assert_includes @target.description, "Target"
        assert_includes @target.description, "<img"
        assert_includes @target.description, "<video"
        assert_includes @target.description, "download="
      end

      %w[up down].each do |direction|
        test "#{direction} creates an attached sibling in the requested position" do
          assert_difference "Creative.count", 1 do
            drop(direction)
          end
          assert_response :success
          created = Creative.find(response.parsed_body["id"])
          assert_equal @parent, created.parent
          assert_equal @owner, created.user
          assert_equal 1, created.files.count
          expected = direction == "up" ? [ created.id, @target.id ] : [ @target.id, created.id ]
          assert_equal expected, @parent.children.order(:sequence).pluck(:id)
          assert_empty @target.reload.files
        end
      end

      test "root sibling belongs to the uploader" do
        @target = Creative.create!(description: "Root", user: @owner)
        drop("down")
        assert_response :success
        created = Creative.find(response.parsed_body["id"])
        assert_nil created.parent
        assert_equal @owner, created.user
      end

      test "rejects unknown target" do
        post "/creatives/0/file_drops", params: { direction: "child", files: [ upload ] }
        assert_response :not_found
      end

      test "rejects malformed drop and missing files" do
        [ { direction: "invalid", files: [ upload ] }, { direction: "up" },
          { direction: "child", files: [ "not a file" ] } ].each do |params|
          assert_no_difference "Creative.count" do
            post path, params: params
          end
          assert_response :unprocessable_entity
        end
      end

      test "rejects writes to an unreadable creative" do
        sign_in_as(users(:three), password: "password")
        %w[up down child].each do |direction|
          assert_no_difference "ActiveStorage::Blob.count" do
            drop(direction)
          end
          assert_response :forbidden
        end
      end

      test "sibling creation requires parent write even when target is writable" do
        @parent.update!(user: users(:three))
        drop("up")
        assert_response :forbidden
        drop("child")
        assert_response :success
      end

      test "linked creative attaches to its origin" do
        origin = @target
        @target = Creative.create!(origin: origin, parent: @parent, user: @owner)
        drop("child")
        assert_response :success
        assert_equal 1, origin.reload.files.count
      end

      test "rejects attaching to read only content before uploading" do
        @target.update_column(:data, { "source" => { "type" => "github_markdown" } })
        assert_no_difference "ActiveStorage::Blob.count" do
          drop("child")
        end
        assert_response :unprocessable_entity
      end

      test "escapes filenames in the new creative description" do
        drop("up", files: [ upload("text/plain", "<script>alert(1)</script>.txt") ])
        assert_response :success
        created = Creative.find(response.parsed_body["id"])
        refute_includes created.description, "<script>"
      end

      test "failed destination creation purges uploaded files" do
        invalid = Creative.new
        result = CreateService::Result.new(creative: invalid, success?: false)
        CreateService.stub :new, ->(**) { Object.new.tap { |service| service.define_singleton_method(:call) { result } } } do
          assert_no_difference [ "Creative.count", "ActiveStorage::Blob.count" ] do
            drop("up")
          end
        end
        assert_response :unprocessable_entity
      end

      test "read permission alone cannot append files" do
        CreativeShare.create!(creative: @target, user: users(:three), permission: :read)
        sign_in_as(users(:three), password: "password")
        drop("child")
        assert_response :forbidden
      end

      test "partial upload failure cleans up earlier blobs" do
        calls = 0
        original = ActiveStorage::Blob.method(:create_after_unfurling!)
        uploader = lambda do |**args|
          calls += 1
          raise IOError, "Upload failed" if calls == 2

          original.call(**args)
        end
        ActiveStorage::Blob.stub :create_after_unfurling!, uploader do
          assert_no_difference [ "Creative.count", "ActiveStorage::Blob.count" ] do
            assert_raises(IOError) do
              FileDropService.new(target: @target, direction: "up", files: [ upload, upload ], user: @owner).call
            end
          end
        end
      end

      test "embedding failure rolls back all changes and purges blobs" do
        @target.define_singleton_method(:embed_attachment_blob!) { |_| raise ActiveRecord::RecordInvalid, self }
        assert_no_difference "ActiveStorage::Blob.count" do
          assert_raises(ActiveRecord::RecordInvalid) do
            FileDropService.new(target: @target, direction: "child", files: [ upload ], user: @owner).call
          end
        end
        assert_equal "Target", @target.reload.description
        assert_empty @target.files
      end

      test "storage upload failure purges the blob saved before transfer" do
        ActiveStorage::Blob.service.stub :upload, ->(*) { raise IOError, "Storage unavailable" } do
          assert_no_difference "ActiveStorage::Blob.count" do
            assert_raises(IOError) do
              FileDropService.new(target: @target, direction: "child", files: [ upload ], user: @owner).call
            end
          end
        end
      end

      private

      def upload(type = "text/plain", name = "notes.txt")
        Rack::Test::UploadedFile.new(StringIO.new("file bytes"), type, original_filename: name)
      end

      def path
        Collavre::Engine.routes.url_helpers.creative_file_drops_path(@target)
      end

      def drop(direction, files: [ upload ])
        post path, params: { direction: direction, files: files }
      end
    end
  end
end
