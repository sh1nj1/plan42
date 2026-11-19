# frozen_string_literal: true

require_relative "../../../test_helper"

module CollavreCompletionApi
  module Api
    module V1
      class CompletionsControllerTest < ActionDispatch::IntegrationTest
        setup do
          @user = users(:one)
          @ai_bot = users(:ai_bot)
          @ai_bot.update!(created_by_id: @user.id)

          @app = Doorkeeper::Application.create!(
            name: "Test", redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
            owner: @user, confidential: true, scopes: "public"
          )
          @token = Doorkeeper::AccessToken.create!(
            application: @app, resource_owner_id: @user.id,
            scopes: "public", expires_in: 1.hour
          )
        end

        test "returns 401 without authentication" do
          post "/api/v1/chat/completions",
               params: { model: "collavre/#{@ai_bot.id}", messages: [ { role: "user", content: "hi" } ] }.to_json,
               headers: { "CONTENT_TYPE" => "application/json" }

          assert_response :unauthorized
        end

        test "returns 400 with empty messages" do
          post "/api/v1/chat/completions",
               params: { model: "collavre/#{@ai_bot.id}", messages: [] }.to_json,
               headers: auth_headers

          assert_response :bad_request
          body = JSON.parse(response.body)
          assert_match(/messages is required/, body.dig("error", "message"))
        end

        test "returns 400 with non-existent email username model" do
          post "/api/v1/chat/completions",
               params: { model: "nonexistent", messages: [ { role: "user", content: "hi" } ] }.to_json,
               headers: auth_headers

          assert_response :bad_request
          body = JSON.parse(response.body)
          assert_match(/Invalid model/, body.dig("error", "message"))
        end

        test "rejects judgment-only agents for both model ID formats and streaming modes" do
          @ai_bot.update!(llm_vendor: "typesafe", llm_model: "jev-latest", searchable: true)
          Collavre::AiClient.stub(:new, ->(**) { flunk "Rejected agent must not create a chat client" }) do
            [ "bot", "collavre/#{@ai_bot.id}" ].product([ false, true ]).each do |model, stream|
              post "/api/v1/chat/completions",
                   params: { model: model, stream: stream,
                             messages: [ { role: "user", content: "hi" } ] }.to_json,
                   headers: auth_headers

              assert_response :bad_request
              assert_equal "Invalid model", JSON.parse(response.body).dig("error", "message")
            end
          end
        end

        [ :judgment_only, :inaccessible ].each do |collision|
          test "resolves advertised model past a #{collision} email collision" do
            @ai_bot.update!(email: "collision@first.example", searchable: false)
            if collision == :judgment_only
              @ai_bot.update!(llm_vendor: "typesafe", llm_model: "jev-latest")
            else
              @ai_bot.update!(created_by_id: users(:two).id)
            end
            agent = Collavre::User.create!(
              name: "Visible chat agent", email: "collision@second.example",
              password: "password123", llm_vendor: "google", llm_model: "gemini-1.5-flash",
              created_by_id: @user.id
            )
            get "/api/v1/models", headers: auth_headers
            assert_includes JSON.parse(response.body).fetch("data").map { |model| model["id"] }, "collision"

            client = Object.new
            client.define_singleton_method(:last_input_tokens) { 0 }
            client.define_singleton_method(:last_output_tokens) { 0 }
            client.define_singleton_method(:chat) { |*| "done" }
            Collavre::AiClient.stub(:new, ->(**options) {
              assert_equal agent.id, options.fetch(:context).fetch(:agent).id
              client
            }) do
              post "/api/v1/chat/completions",
                   params: { model: "collision", messages: [ { role: "user", content: "hi" } ] }.to_json,
                   headers: auth_headers
              assert_response :success
              assert_includes response.body, "done"
            end
          end
        end

        test "returns 400 with external model name" do
          post "/api/v1/chat/completions",
               params: { model: "gpt-4", messages: [ { role: "user", content: "hi" } ] }.to_json,
               headers: auth_headers

          assert_response :bad_request
          body = JSON.parse(response.body)
          assert_match(/Invalid model/, body.dig("error", "message"))
        end

        test "resolves agent by email username" do
          post "/api/v1/chat/completions",
               params: { model: "bot", messages: [ { role: "user", content: "hi" } ] }.to_json,
               headers: auth_headers

          # Agent resolved successfully — should not return "Invalid model" error
          body = JSON.parse(response.body)
          refute_equal "Invalid model", body.dig("error", "message")
        end

        test "returns 400 with non-existent agent" do
          post "/api/v1/chat/completions",
               params: { model: "collavre/999999", messages: [ { role: "user", content: "hi" } ] }.to_json,
               headers: auth_headers

          assert_response :bad_request
        end

        test "returns 400 for non-accessible agent" do
          other_user = users(:two)
          other_token = Doorkeeper::AccessToken.create!(
            application: @app, resource_owner_id: other_user.id,
            scopes: "public", expires_in: 1.hour
          )

          post "/api/v1/chat/completions",
               params: { model: "collavre/#{@ai_bot.id}", messages: [ { role: "user", content: "hi" } ] }.to_json,
               headers: { "Authorization" => "Bearer #{other_token.token}", "CONTENT_TYPE" => "application/json" }

          assert_response :bad_request
        end

        [ false, true ].each do |stream|
          test "records selected agent and human caller for stream=#{stream}" do
            owner = users(:two)
            @ai_bot.update!(created_by_id: owner.id, searchable: true)
            factory = lambda do |**options|
              context = options.fetch(:context)
              assert_equal @user, context[:user]
              collector = Collavre::LlmUsage::Recorder.new(
                context: context, vendor: options[:vendor], model: options[:model])
              client = Object.new
              client.define_singleton_method(:last_input_tokens) { 10 }
              client.define_singleton_method(:last_output_tokens) { 4 }
              client.define_singleton_method(:chat) do |_contents, &block|
                collector.finish(RubyLLM::Message.new(role: :assistant, content: "done",
                  input_tokens: 10, output_tokens: 4))
                block&.call("done")
                "done"
              end
              client
            end
            Collavre::AiClient.stub(:new, factory) do
              assert_difference "Collavre::LlmUsage.count", 1 do
                post "/api/v1/chat/completions",
                     params: { model: "collavre/#{@ai_bot.id}", stream: stream,
                               messages: [ { role: "user", content: "hi" } ] }.to_json,
                     headers: auth_headers
                assert_response :success
                assert_includes response.body, "done"
              end
            end
            usage = Collavre::LlmUsage.last
            assert_equal @ai_bot.id, usage.agent_id
            assert_equal owner.id, usage.owner_id
            assert_equal @user.id, usage.requester_id
            assert_includes Collavre::LlmUsage.visible_to(@user), usage
            assert_includes Collavre::LlmUsage.visible_to(owner), usage
          end
        end

        private

        def auth_headers
          { "Authorization" => "Bearer #{@token.token}", "CONTENT_TYPE" => "application/json" }
        end
      end
    end
  end
end
