require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CreativeRetrievalService
    extend T::Sig
    extend ToolMeta

    tool_name "creative_retrieval_service"
    tool_description "Retrieve creatives by ID or query text. without query  or ID, it will return root creatives. Returns a list of matching creatives with their details, supporting both hierarchical tree and flat list formats.\n\nA Creative is a content block that functions like a task, organized in a tree structure similar to a to-do list. You can navigate the tree at any level as a structured document, with progress automatically calculated to show what’s been completed.\n\ne.g.\n- When user say creative or Test creative, it means \"Test\" creative and it's children as a writing page.\n- Summary of Test creative? - you need to search \"Test\" creatives with level 3 or more and find the title is \"Test\" or similar and make summary of that."

    tool_param :id, description: "The ID of the creative to retrieve."
    tool_param :query, description: "Text to search for in creative descriptions."
    tool_param :level, description: "Creative tree depth to return (default: 3).", required: false
    tool_param :simple, description: "If true, returns a simplified flat list. If false (default), returns a tree structure with HTML.", required: false

    sig { params(id: T.nilable(Integer), query: T.nilable(String), level: T.nilable(Integer), simple: T.nilable(T::Boolean)).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def call(id: nil, query: nil, level: 3, simple: false)
      level ||= 3
      simple ||= false

      # Ensure fresh permission cache for this tool execution
      Current.creative_share_cache = nil if Current.respond_to?(:creative_share_cache=)

      # Mock session and request setup
      setup_mock_environment

      controller = CreativesController.new
      setup_controller(controller)

      if id.present?
        # Get the creative details (show)
        show_result = dispatch_request(controller, :show, id: id, format: :json)
        return show_result if show_result.is_a?(Array) && show_result.first[:error]

        # Get the children (index with id acts as parent filter)
        index_result = dispatch_request(controller, :index, id: id, search: query, simple: simple, level: level, format: :json)
        return index_result if index_result.is_a?(Array) && index_result.first[:error]

        # Combine results
        # show_result is expected to be a hash of the creative
        # index_result is expected to be a list of children or simple list

        # Parse show result
        creative_details = JSON.parse(show_result[:body], symbolize_names: true)

        # Parse index result
        children_data = JSON.parse(index_result[:body], symbolize_names: true)
        filtered_children = filter_result(children_data)

        # Merge
        # We construct a tree node for the parent, with the children attached
        parent_node = filter_tree([ creative_details ]).first
        parent_node[:children] = filtered_children

        [ parent_node ]
      else
        # Normal index call
        result = dispatch_request(controller, :index, search: query, simple: simple, level: level, format: :json)

        if result[:status] == 200
           parsed = JSON.parse(result[:body], symbolize_names: true)
           filter_result(parsed)
        else
           [ { error: "Controller returned status #{result[:status]}", body: result[:body] } ]
        end
      end
    end

    private

    def setup_mock_environment
      raise "Current.user is required" unless Current.user
      unless Current.session
        require "ostruct"
        Current.session = OpenStruct.new(user: Current.user, persisted?: false)
      end
    end

    def setup_controller(controller)
      # Stub cookies
      controller.define_singleton_method(:cookies) do
        @mock_cookies ||= begin
          jar = OpenStruct.new
          def jar.signed; self; end
          def jar.encrypted; self; end
          def jar.[](key); nil; end
          def jar.delete(key); nil; end
          jar
        end
      end
    end

    def dispatch_request(controller, action, params)
      env = Rack::MockRequest.env_for(
        "/creatives",
        method: "GET",
        params: params.compact,
        "HTTP_X_ORIGIN_SECRET" => ENV["ORIGIN_SHARED_SECRET"] # Internal call
      )
      controller.request = ActionDispatch::Request.new(env)
      controller.response = ActionDispatch::Response.new
      controller.process(action)

      { status: controller.response.status, body: controller.response.body }
    end

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
