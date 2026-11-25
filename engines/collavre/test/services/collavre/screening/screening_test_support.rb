# frozen_string_literal: true

module ScreeningTestSupport
  FakeScreener = Struct.new(:id, :model, :answers, :calls) do
    def judge(input)
      calls << input
      answer = answers.is_a?(Array) ? answers.shift : answers
      raise answer if answer.is_a?(Exception)

      { "answers" => { "injection" => { "probability" => answer } } }
    end
  end

  def fake_screener(answers, id: "system")
    FakeScreener.new(id, "jev-latest", answers, [])
  end

  def create_agent(owner, name:, vendor: "google", model: "gemini-test")
    Collavre::User.create!(email: "#{name.parameterize}-#{SecureRandom.hex(3)}@agent.collavre.local", name: name,
      password: SecureRandom.hex(16), llm_vendor: vendor, llm_model: model,
      created_by_id: owner&.id, searchable: false)
  end

  def enable_screening!
    Collavre::SystemSetting.create!(key: "screening_enabled", value: "true")
  end

  def with_screeners(screeners, &block)
    Collavre::Screening::ScreenerResolver.stub(:for, ->(**) { screeners }, &block)
  end
end
