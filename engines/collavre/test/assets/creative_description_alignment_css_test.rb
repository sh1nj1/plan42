require "test_helper"

class CreativeDescriptionAlignmentCssTest < ActiveSupport::TestCase
  setup do
    @css = Rails.root.join("engines/collavre/app/assets/stylesheets/collavre/creatives.css").read
  end

  test "justifies creative descriptions only when the preference class is present" do
    alignment_rule = @css.match(/\.creative-description-justified \.creative-content \{(?<declarations>[^}]*)\}/)

    assert alignment_rule
    assert_includes alignment_rule[:declarations], "text-align: justify;"
  end

  test "leaves creative descriptions unaligned when the preference class is absent" do
    creative_content_rule = @css.match(/(?<!justified )\.creative-content \{(?<declarations>[^}]*)\}/)

    assert creative_content_rule
    refute_includes creative_content_rule[:declarations], "text-align:"
  end
end
