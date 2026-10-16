require_relative "../application_system_test_case"

class PublicDocumentWidthTest < ApplicationSystemTestCase
  test "anonymous document previews fill the public title row on desktop and mobile" do
    SystemSetting.where(key: "creatives_login_required").destroy_all
    creative = Creative.create!(user: users(:one), description: "Public document")
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("# Document"), filename: "notes.md", content_type: "text/markdown")
    creative.embed_attachment_blob!(blob)
    perform_enqueued_jobs { CreativeShare.create!(creative: creative, user: nil, permission: :read) }
    [ 1280, 375 ].each do |width|
      page.current_window.resize_to(width, 900)
      visit collavre.public_creative_path(public_id: creative.ensure_public_id!, slug: creative.public_slug)
      assert_selector "iframe.document-preview-frame"
      dimensions = page.evaluate_script(<<~JS)
        (() => {
          const frame = document.querySelector('iframe.document-preview-frame').getBoundingClientRect();
          const row = document.querySelector('.creative-row-start').getBoundingClientRect();
          return { frameRight: frame.right, rowRight: row.right, frameWidth: frame.width,
            mainWidth: document.querySelector('main').getBoundingClientRect().width,
            viewport: innerWidth, documentWidth: document.documentElement.scrollWidth };
        })()
      JS
      assert_in_delta [ dimensions["viewport"], 960 ].min, dimensions["mainWidth"], 2
      assert_in_delta dimensions["rowRight"], dimensions["frameRight"], 2
      assert_operator dimensions["frameWidth"], :>, dimensions["mainWidth"] * 0.75
      assert_operator dimensions["documentWidth"], :<=, dimensions["viewport"]
    end
  end
end
