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
    # Cache every visible source, including the parent title and breadcrumb.
    [ [ parent, "Public document", "공개 문서" ], [ child, "Public English content", "공개 글 번역" ] ].each do |creative, original, translated|
      CollavreTranslation::Translation.create!(translatable: creative, target_locale: "ko",
        source_digest: CollavreTranslation::Translation.digest(creative.effective_description),
        status: "completed", content: [ { original: original, translated: translated } ].to_json)
    end

    visit collavre.creatives_path(id: parent.id, lang: "ko")
    assert_selector "creative-tree-row[creative-id='#{child.id}']", text: "공개 글 번역"
    assert_selector "creative-tree-row[creative-id='#{parent.id}']", text: "공개 문서"
    assert_equal "<p>Public English content</p>", child.reload.description
    find('[aria-controls=creative-overflow-menu]').click
    find('.creative-translation-toggle').click
    assert_selector "creative-tree-row[creative-id='#{child.id}']", text: "Public English content"
    assert_selector "creative-tree-row[creative-id='#{parent.id}']", text: "Public document"
  ensure
    CollavreTranslation.model = nil
  end
end
