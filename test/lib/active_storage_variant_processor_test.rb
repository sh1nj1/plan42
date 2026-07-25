require "test_helper"

# Guards the gem backing Active Storage's variant processor.
#
# Active Storage resolves the processor class lazily: ActiveStorage::Transformers::Vips only
# touches ImageProcessing::Vips inside #processor, which runs when a variant is actually
# processed. image_processing 2.0 turned ruby-vips and mini_magick into soft dependencies, so a
# bundle that drops ruby-vips boots clean, passes a suite that never renders a variant, and then
# raises LoadError on the first avatar or comment image in production. Resolving the processor
# eagerly here turns that into a CI failure instead.
class ActiveStorageVariantProcessorTest < ActiveSupport::TestCase
  test "the configured variant processor resolves its backing gem" do
    # Pinned rather than read from config: the ruby-vips dependency in the Gemfile is only the
    # right one while :vips is the processor. Switching processors has to update both.
    assert_equal :vips, ActiveStorage.variant_processor
    assert_equal ActiveStorage::Transformers::Vips, ActiveStorage.variant_transformer,
      "variant_transformer is unset — Active Storage swallowed a LoadError while booting"

    assert_equal ImageProcessing::Vips,
      ActiveStorage.variant_transformer.new({}).send(:processor)
  end
end
