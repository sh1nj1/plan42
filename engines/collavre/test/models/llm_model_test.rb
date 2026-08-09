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

  test "remember ignores blank values" do
    assert_no_difference("Collavre::LlmModel.count") do
      assert_nil Collavre::LlmModel.remember!(vendor: "openai", name: "")
      assert_nil Collavre::LlmModel.remember!(vendor: "", name: "gpt-5")
    end
  end

  test "remember returns the existing model when concurrent creation wins" do
    existing = Collavre::LlmModel.create!(llm_vendor: "openai", name: "gpt-5")

    Collavre::LlmModel.stub(:find_or_create_by!, ->(**) { raise ActiveRecord::RecordNotUnique }) do
      assert_equal existing, Collavre::LlmModel.remember!(vendor: "openai", name: "gpt-5")
    end
  end

  test "deleting a creator keeps the shared model" do
    creator = User.create!(email: "model-owner@example.com", password: "password", name: "Owner")
    model = Collavre::LlmModel.create!(llm_vendor: "openai", name: "gpt-5", creator: creator)

    creator.destroy!

    assert_nil model.reload.creator
  end
end
