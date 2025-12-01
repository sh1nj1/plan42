require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CreativeRetrievalService
    extend T::Sig
    extend ToolMeta

    tool_name "creative_retrieval_service"
    tool_description "Retrieve creatives by ID or query text. without query  or ID, it will return root creatives. Returns a list of matching creatives with their details, supporting both hierarchical tree and flat list formats."

    tool_param :id, description: "The ID of the creative to retrieve."
    tool_param :query, description: "Text to search for in creative descriptions."
    tool_param :level, description: "Creative tree depth to return (default: 1)."
    tool_param :simple, description: "If true, returns a simplified flat list. If false (default), returns a tree structure with HTML."

    sig { params(id: T.nilable(Integer), query: T.nilable(String), level: Integer, simple: T.nilable(T::Boolean)).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def call(id: nil, query: nil, level: 1, simple: false)
      raise "Current.user is required" unless Current.user

      # Mock session if missing, to pass Authentication concern
      unless Current.session
        # Create a mock session object that responds to user and persisted?
        # We use OpenStruct for simplicity, assuming Session interface is duck-typed enough for Authentication concern
        require "ostruct"
        mock_session = OpenStruct.new(user: Current.user, persisted?: false)
        Current.session = mock_session
      end

      controller = CreativesController.new

      # Create a mock request
      # We use Rack::MockRequest to generate a proper env
      env = Rack::MockRequest.env_for(
        "/creatives",
        method: "GET",
        params: {
          id: id,
          search: query,
          simple: simple.presence,
          level: level,
          format: :json
        }.compact,
      )

      controller.request = ActionDispatch::Request.new(env)
      controller.response = ActionDispatch::Response.new

      # Stub cookies to avoid ActionDispatch::Cookies middleware dependency
      def controller.cookies
        @mock_cookies ||= begin
          jar = OpenStruct.new
          def jar.signed
            self
          end
          def jar.encrypted
            self
          end
          def jar.[](key)
            nil
          end
          def jar.delete(key)
            nil
          end
          jar
        end
      end

      # Dispatch the action
      controller.process(:index)

      # Parse the response
      if controller.response.successful?
        result = JSON.parse(controller.response.body, symbolize_names: true)
        filter_result(result)
      else
        [ { error: "Controller returned status #{controller.response.status}", body: controller.response.body } ]
      end
    end

    private

    def filter_result(result)
      if result.is_a?(Array)
        # Simple mode
        result.map { |item| item.slice(:id, :description, :progress) }
      elsif result.is_a?(Hash) && result[:creatives].is_a?(Array)
        # Normal mode (Tree)
        filter_tree(result[:creatives])
      else
        []
      end
    end

    def filter_tree(nodes)
      nodes.map do |node|
        description = if node.dig(:templates, :description_html)
          Rails::Html::FullSanitizer.new.sanitize(node.dig(:templates, :description_html))
        else
          node[:description]
        end

        {
          id: node[:id],
          description: description&.strip,
          progress: node.dig(:inline_editor_payload, :progress) || node[:progress],
          children: node.dig(:children_container, :nodes) ? filter_tree(node.dig(:children_container, :nodes)) : []
        }
      end
    end
  end
end
