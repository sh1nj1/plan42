require "test_helper"

module Collavre
  class AttachmentsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "attach_owner@example.com", password: TEST_PASSWORD,
                           name: "Attach Owner", email_verified_at: Time.current)
      sign_in_as(@user)
    end

    def make_blob
      ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("hello world"), filename: "f.txt", content_type: "text/plain"
      )
    end

    def blob_ref_html(signed_id)
      %(<p><a href="/public-assets/blobs/#{signed_id}/f.txt" download>f.txt</a></p>)
    end

    # The P1: description HTML is the source of truth and a blob can be shared
    # across creatives (HTML copied between them). The editor still fires
    # DELETE /attachments/:signed_id for a removed node after its PATCH lands.
    # Purging unconditionally there would delete a blob still referenced by
    # another creative. The destroy path must guard like the reconcile path.
    test "does not purge a blob still referenced by another creative" do
      blob = make_blob
      signed_id = blob.signed_id

      # Two creatives the user can edit both embed the same blob; the editor
      # removed the node from A (its description no longer references it) and
      # fires DELETE for the signed_id. B still references it.
      Collavre::Creative.create!(description: "<p>x</p>", user: @user)
      Collavre::Creative.create!(description: blob_ref_html(signed_id), user: @user)

      delete collavre.attachment_path(signed_id)
      assert_response :no_content

      assert ActiveStorage::Blob.exists?(blob.id),
             "shared blob must survive removal from one creative"
    end

    # A direct-upload blob the editor inserted and the user removed before it
    # was ever attached (removed-then-save, so reconcile never saw it in the
    # saved HTML) is a true orphan: no attachment, no referencing description.
    # The cleanup DELETE the editor fires must purge it instead of 403-ing and
    # stranding it in storage.
    test "purges a true orphan blob (unattached, unreferenced)" do
      blob = make_blob
      assert_empty blob.attachments
      assert_not Collavre::Creative.where("description LIKE ?", "%#{blob.signed_id}%").exists?

      delete collavre.attachment_path(blob.signed_id)
      assert_response :no_content

      assert_not ActiveStorage::Blob.exists?(blob.id),
                 "true orphan blob must be purged"
    end

    # The orphan-purge authorization must not become an open door: a blob still
    # attached to another record is not an orphan, so a caller without
    # ownership/writable-reference still gets 403.
    test "403 when an attached blob is not owned or writably referenced by caller" do
      sign_out
      owner = User.create!(email: "attach_blob_owner@example.com", password: TEST_PASSWORD,
                           name: "Blob Owner", email_verified_at: Time.current)
      other = User.create!(email: "attach_blob_other@example.com", password: TEST_PASSWORD,
                           name: "Blob Other", email_verified_at: Time.current)
      sign_in_as(other)

      blob = make_blob
      owner_creative = Collavre::Creative.create!(description: "<p>x</p>", user: owner)
      owner_creative.files.attach(blob)

      delete collavre.attachment_path(blob.signed_id)
      assert_response :forbidden
      assert ActiveStorage::Blob.exists?(blob.id)
    end

    test "403 when caller cannot reference or own the blob" do
      sign_out
      other = User.create!(email: "attach_other@example.com", password: TEST_PASSWORD,
                           name: "Attach Other", email_verified_at: Time.current)
      sign_in_as(other)

      blob = make_blob
      # referenced only by a creative owned by @user, not `other`
      Collavre::Creative.create!(description: blob_ref_html(blob.signed_id), user: @user)

      delete collavre.attachment_path(blob.signed_id)
      assert_response :forbidden
      assert ActiveStorage::Blob.exists?(blob.id)
    end
  end
end
