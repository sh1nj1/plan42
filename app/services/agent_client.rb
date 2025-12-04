class AgentClient < AiClient
  def initialize(vendor:, model:, system_prompt:, llm_api_key: nil, agent_run_id:)
    super(vendor: vendor, model: model, system_prompt: system_prompt, llm_api_key: llm_api_key)
    @agent_run_id = agent_run_id
  end

  private

  def build_conversation(tools = [])
    api_key = @llm_api_key.presence || ENV["GEMINI_API_KEY"]
    RubyLLM.context { |config| config.gemini_api_key = api_key }
           .chat(model: model).tap do |chat|
      chat.with_instructions(system_prompt)
      if tools.any?
        # Resolve tool names to classes using the gem's helper
        tool_classes = Tools::MetaToolService.ruby_llm_tools(tools)

        # Wrap tools to record actions
        wrapped_classes = tool_classes.map { |tc| wrap_tool(tc) }

        wrapped_classes.each do |tool_class|
          chat.with_tool(tool_class)
        end
      end
    end
  end

  def wrap_tool(tool_class)
    agent_run_id = @agent_run_id

    # Create a dynamic subclass to intercept the call method
    Class.new(tool_class) do
      # We need to capture agent_run_id in the closure
      define_method :call do |*args, **kwargs, &block|
        tool_name = self.class.tool_name

        provided_arguments = if kwargs.any?
          kwargs
        elsif args.one? && args.first.is_a?(Hash)
          args.first
        else
          args
        end

        action = AgentAction.create!(
          agent_run_id: agent_run_id,
          tool_name: tool_name,
          arguments: provided_arguments,
          status: "running"
        )

        begin
          # Call the original tool's call method
          result = super(*args, **kwargs, &block)

          # Update action with success
          action.update!(result: result.to_s, status: "success")

          result
        rescue => e
          # Update action with error
          action.update!(result: e.message, status: "error")
          raise e
        end
      end

      # Forward class methods required by RubyLLM/FastMcp
      def self.tool_name
        superclass.tool_name
      end

      def self.description
        superclass.description
      end

      def self.input_schema
        superclass.input_schema
      end

      # Ensure the class has a name for debugging if possible, though anonymous is fine
      def self.name
        "AgentWrapper_#{superclass.name}"
      end
    end
  end
end
