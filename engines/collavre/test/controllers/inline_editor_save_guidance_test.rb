require "test_helper"

class InlineEditorSaveGuidanceTest < ActionDispatch::IntegrationTest
  {
    en: [
      "Describe the creative… Changes save automatically and when you close the editor.",
      "Write in Markdown… Changes save automatically and when you close the editor.",
      "Save and close (Esc)"
    ],
    ko: [
      "크리에이티브를 설명해주세요… 자동 저장되며, 닫기 버튼을 눌러도 저장됩니다.",
      "마크다운으로 작성… 자동 저장되며, 닫기 버튼을 눌러도 저장됩니다.",
      "저장하고 닫기 (Esc)"
    ]
  }.each do |locale, (rich_text, markdown, close)|
    test "inline editor explains saving in #{locale}" do
      user = users(:one)
      user.update!(locale: locale)
      sign_in_as(user, password: "password")

      get creatives_path

      assert_response :success
      assert_select "#lexical-inline-editor[data-placeholder=?]", rich_text
      assert_select "#markdown-editor-textarea[placeholder=?]", markdown
      assert_select "#inline-close[title=?]", close
    end
  end
end
