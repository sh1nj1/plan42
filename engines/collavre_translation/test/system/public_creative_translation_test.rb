require_relative "../../../collavre/test/application_system_test_case"

class PublicCreativeTranslationSystemTest < ApplicationSystemTestCase
  test "anonymous public document uses lang override and can restore the original" do
    CollavreTranslation.model = "test-model"
    author = users(:one)
    parent = Collavre::Creative.create!(user: author, description: "Public document")
    child = Collavre::Creative.create!(user: author, parent: parent, description: "<p>Public English content</p>")
    [ parent, child ].each do |creative|
      Collavre::CreativeSharesCache.create!(creative: creative, user: nil, permission: :read)
    end
    record = CollavreTranslation::Translation.request!(child, "ko")
    record.update!(status: "completed", content: [ { original: "Public English content", translated: "공개 글 번역" } ].to_json)

    visit collavre.creatives_path(id: parent.id, lang: "ko")
    assert_selector "creative-tree-row[creative-id='#{child.id}']", text: "공개 글 번역"
    assert_equal "<p>Public English content</p>", child.reload.description
    find('[aria-controls=creative-overflow-menu]').click
    find('.creative-translation-toggle').click
    assert_selector "creative-tree-row[creative-id='#{child.id}']", text: "Public English content"
  ensure
    CollavreTranslation.model = nil
  end
end
