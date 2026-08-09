require "test_helper"

class LlmModelTest < ActiveSupport::TestCase
  test "normalizes vendor and model name" do
    model = Collavre::LlmModel.create!(
      llm_vendor: " Anthropic ",
      name: " claude-sonnet-4 ",
      creator: users(:one)
    )

    assert_equal "anthropic", model.llm_vendor
    assert_equal "claude-sonnet-4", model.name
  end

  test "requires a unique model name within each vendor" do
    Collavre::LlmModel.create!(llm_vendor: "openai", name: "gpt-5")

    duplicate = Collavre::LlmModel.new(llm_vendor: "openai", name: "gpt-5")
    same_name_other_vendor = Collavre::LlmModel.new(llm_vendor: "openrouter", name: "gpt-5")

    refute duplicate.valid?
    assert duplicate.errors.of_kind?(:name, :taken)
    assert same_name_other_vendor.valid?
  end

  test "bounds vendor and model name lengths" do
    model = Collavre::LlmModel.new(
      llm_vendor: "v" * Collavre::LlmModel::MAX_VENDOR_LENGTH,
      name: "m" * Collavre::LlmModel::MAX_NAME_LENGTH
    )

    model.save!
    assert_predicate model, :persisted?

    model.llm_vendor = "v" * (Collavre::LlmModel::MAX_VENDOR_LENGTH + 1)
    assert_not model.valid?
    assert model.errors.of_kind?(:llm_vendor, :too_long)

    model.llm_vendor = "vendor"
    model.name = "m" * (Collavre::LlmModel::MAX_NAME_LENGTH + 1)
    assert_not model.valid?
    assert model.errors.of_kind?(:name, :too_long)
  end

  test "remember creates one shared model and records its first creator" do
    creator = users(:one)

    assert_difference("Collavre::LlmModel.count", 1) do
      2.times do
        Collavre::LlmModel.remember!(
          vendor: " OpenAI ",
          name: " gpt-5.2 ",
          creator: creator
        )
      end
    end

    model = Collavre::LlmModel.find_by!(llm_vendor: "openai", name: "gpt-5.2")
    assert_equal creator, model.creator
  end

  test "remember marks an existing model as recently used" do
    model = Collavre::LlmModel.create!(
      llm_vendor: "openai",
      name: "gpt-5",
      updated_at: 1.year.ago
    )

    assert_changes -> { model.reload.updated_at } do
      Collavre::LlmModel.remember!(vendor: "openai", name: "gpt-5")
    end
  end

  test "remember ignores blank values" do
    assert_no_difference("Collavre::LlmModel.count") do
      assert_nil Collavre::LlmModel.remember!(vendor: "openai", name: "")
      assert_nil Collavre::LlmModel.remember!(vendor: "", name: "gpt-5")
    end
  end

  test "remember rejects an oversized model name without saving it" do
    oversized_name = "m" * (Collavre::LlmModel::MAX_NAME_LENGTH + 1)

    assert_no_difference("Collavre::LlmModel.count") do
      error = assert_raises(ActiveRecord::RecordInvalid) do
        Collavre::LlmModel.remember!(vendor: "openai", name: oversized_name)
      end
      assert error.record.errors.of_kind?(:name, :too_long)
    end
  end

  test "remember returns the existing model when concurrent creation wins" do
    existing = Collavre::LlmModel.create!(llm_vendor: "openai", name: "gpt-5")

    Collavre::LlmModel.stub(:find_or_create_by!, ->(**) { raise ActiveRecord::RecordNotUnique }) do
      assert_equal existing, Collavre::LlmModel.remember!(vendor: "openai", name: "gpt-5")
    end
  end

  test "suggestions are bounded to the most recently used models" do
    Collavre::LlmModel.delete_all
    rows = (1..(Collavre::LlmModel::MAX_SUGGESTIONS + 1)).map do |index|
      {
        llm_vendor: "vendor-#{index}",
        name: "model-#{index}",
        created_at: index.minutes.ago,
        updated_at: index.minutes.ago
      }
    end
    Collavre::LlmModel.insert_all!(rows)

    suggestions = Collavre::LlmModel.suggestions.to_a

    assert_equal Collavre::LlmModel::MAX_SUGGESTIONS, suggestions.size
    assert_not_includes suggestions.map(&:name), "model-101"
    assert_equal suggestions.sort_by { |model| [ model.llm_vendor, model.name ] }, suggestions
  end

  test "remember prunes the oldest shared suggestion beyond the global cap" do
    Collavre::LlmModel.delete_all
    oldest = Collavre::LlmModel.create!(
      llm_vendor: "old-vendor",
      name: "old-model",
      created_at: 1.year.ago,
      updated_at: 1.year.ago
    )
    rows = (1...Collavre::LlmModel::MAX_SUGGESTIONS).map do |index|
      {
        llm_vendor: "vendor-#{index}",
        name: "model-#{index}",
        created_at: index.minutes.ago,
        updated_at: index.minutes.ago
      }
    end
    Collavre::LlmModel.insert_all!(rows)

    remembered = Collavre::LlmModel.remember!(vendor: "openai", name: "new-model")

    assert_equal "new-model", remembered.name
    assert_equal Collavre::LlmModel::MAX_SUGGESTIONS, Collavre::LlmModel.count
    refute Collavre::LlmModel.exists?(oldest.id)
  end

  test "deleting a creator keeps the shared model" do
    creator = User.create!(email: "model-owner@example.com", password: "password", name: "Owner")
    model = Collavre::LlmModel.create!(llm_vendor: "openai", name: "gpt-5", creator: creator)

    creator.destroy!

    assert_nil model.reload.creator
  end
end
