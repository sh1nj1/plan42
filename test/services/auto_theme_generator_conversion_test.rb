require "test_helper"

class AutoThemeGeneratorConversionTest < ActiveSupport::TestCase
  def setup
    @generator = AutoThemeGenerator.new
  end

  test "converts oklch to hex correctly" do
    # White
    # oklch(100% 0 0) -> #ffffff
    hex = @generator.send(:convert_oklch_to_hex, "oklch(100% 0 0)")
    assert_equal "#ffffff", hex

    # Black
    # oklch(0% 0 0) -> #000000
    hex = @generator.send(:convert_oklch_to_hex, "oklch(0% 0 0)")
    assert_equal "#000000", hex

    # Approximate check for red
    # oklch(62.8% 0.25768330773615683 29.2338851923426) is close to #ff0000
    # Let's verify a stable value.
    # oklch(0.62796 0.25768 29.23389) -> Red #ff0000
    hex = @generator.send(:convert_oklch_to_hex, "oklch(62.796% 0.25768 29.23389)")
    assert_equal "#ff0000", hex
  end

  test "process_variables converts values in hash" do
    input = {
      "--color-bg" => "oklch(100% 0 0)",
      "--color-text" => "#123456"
    }
    output = @generator.send(:process_variables, input)

    assert_equal "#ffffff", output["--color-bg"]
    assert_equal "#123456", output["--color-text"] # Should remain unchanged
  end
end
