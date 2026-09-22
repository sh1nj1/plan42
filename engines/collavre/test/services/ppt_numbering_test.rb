require "test_helper"

class PptNumberingTest < ActiveSupport::TestCase
  setup do
    @renderer = Collavre::PptImporter.allocate
  end

  test "formats decimal alphabetic and roman punctuation" do
    { [ "arabicPeriod", 12 ] => "12.", [ "arabicPlain", 12 ] => "12",
      [ "alphaUcParenBoth", 27 ] => "(AA)", [ "alphaLcPeriod", 26 ] => "z.",
      [ "romanLcParenR", 49 ] => "xlix)", [ "romanUcPeriod", 1994 ] => "MCMXCIV." }.each do |(type, number), expected|
      assert_equal expected, @renderer.send(:numbered_marker, type, number)
    end
  end

  test "empty text bodies are safe" do
    assert_empty @renderer.send(:render_paragraphs, nil, {})
  end
end
