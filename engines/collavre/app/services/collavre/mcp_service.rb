module Collavre
  require "digest"
  require "set"
  require "monitor"

  class McpService
    # ToolMeta.registry is process-wide. Evaluating a source and rolling back
    # what it added must not interleave with another registration, or one
    # approval's rollback removes the class the other just registered.
    REGISTRY_LOCK = Monitor.new

    # --- Registration Logic (from MetaToolService) ---

    # expected_name is the McpTool name recorded from the Creative. The name the
    # evaluated class actually declares must match it, otherwise the tool would
    # run without its McpTool row and filter_tools would treat it as a system tool.
    def self.register_tool_from_source(source_code, expected_name: nil)
      # Extract tool name for logging context
      tool_name_match = source_code.match(/tool_name\s+["'](.+?)["']/)
      tool_name = expected_name || (tool_name_match ? tool_name_match[1] : "unknown_tool")

      before_call = proc do |tool_instance, method_name, args|
        # Store args for after_call access if needed, or just log start
        # Using thread local to pass data to after_call if we want to correlate exact timing or args
        Thread.current[:mcp_tool_args_stack] ||= []
        Thread.current[:mcp_tool_args_stack].push(args)
      end

      after_call = proc do |tool_instance, method_name, result|
        # Retrieve args
        args = Thread.current[:mcp_tool_args_stack]&.pop || {}

        # Create activity log
        # We need a user to attribute this to.
        # If executed in a background job (Task), Current.user is set.
        # If executed via API, Current.user is set.
        user = Current.user
        creative = tool_instance&.try(:creative_context) rescue nil # Assuming some way to get context if needed, or nil

        ActivityLog.create!(
          activity: "tool_execution",
          user: user,
          creative: creative, # Optional: if we can link it back to a creative
          log: {
            tool_name: tool_name,
            method: method_name,
            args: args,
            result: result
          }
        )
      rescue StandardError => e
        Rails.logger.error("Failed to log tool activity: #{e.message}")
      end

      result = register_with_writer(source_code, expected_name, before_call: before_call, after_call: after_call)
      Rails.logger.info("Registered tool: #{result}")

      if result[:error]
        error_msg = "Failed to register tool: #{result[:error]}"
        Rails.logger.error(error_msg)
        raise error_msg
      end
    rescue StandardError => e
      Rails.logger.error("Failed to register tool from source: #{e.message}")
      raise e
    end

    def self.register_with_writer(source_code, expected_name, before_call:, after_call:)
      writer = ::Tools::MetaToolWriteService.new
      REGISTRY_LOCK.synchronize do
        next writer.register_tool_from_source(source: source_code, before_call: before_call, after_call: after_call) unless expected_name

        register_verified_source(writer, source_code, expected_name, before_call: before_call, after_call: after_call)
      end
    end
    private_class_method :register_with_writer

    # Same steps as MetaToolWriteService#register_tool_from_source, with a name
    # check between evaluating the source and building the tool classes.
    # Evaluating the source adds every class that extends ToolMeta to the
    # registry, even when the class body raises afterwards. Only the verified
    # service class may stay; everything else the source added is rolled back.
    def self.register_verified_source(writer, source_code, expected_name, before_call:, after_call:)
      class_name = writer.send(:extract_class_name, source_code)
      return { error: "class_name is required for register" } if class_name.blank?

      registered_before = ToolMeta.registry.dup
      result = evaluate_and_verify(source_code, class_name, expected_name)
      keep = result.is_a?(Class) ? [ result ] : []
      ToolMeta.registry.reject! { |klass| !registered_before.include?(klass) && !keep.include?(klass) }
      return result unless keep.any?

      writer.register_tool(class_name, before_call: before_call, after_call: after_call)
    end
    private_class_method :register_verified_source

    # Returns the service class when it declares expected_name, else an error hash.
    def self.evaluate_and_verify(source_code, class_name, expected_name)
      begin
        Object.class_eval(source_code)
      rescue StandardError, ScriptError => e
        return { error: "Failed to evaluate source: #{e.message}" }
      end

      service_class = class_name.safe_constantize
      return { error: "#{class_name} is not defined by the source" } unless service_class.is_a?(Class)

      declared = service_class.try(:tool_metadata)&.dig(:name)
      return service_class if declared == expected_name

      ToolMeta.registry.delete(service_class)
      { error: "#{class_name} declares tool_name #{declared.inspect}, expected #{expected_name.inspect}" }
    end
    private_class_method :evaluate_and_verify

    def self.filter_tools(tools, user)
      return [] if tools.blank?

      # Identify dynamic tools (user-defined) vs system tools.
      # Tools can be objects (FastMcp::Tool) or Hashes (from MetaToolService)
      registered_names = tools.map do |tool|
        if tool.respond_to?(:tool_name)
          tool.tool_name
        elsif tool.is_a?(Hash)
          tool[:name] || tool["name"]
        end
      end

      # Check strict loading? No, simple where is fine.
      dynamic_tools = McpTool.where(name: registered_names).includes(:creative)
      dynamic_tool_names = dynamic_tools.pluck(:name).to_set

      # Build set of tool names the user has permission to run
      # User needs write permission on the creative to run its tools
      accessible_tool_names = if user
                                dynamic_tools.select do |mcp_tool|
                                  mcp_tool.creative&.has_permission?(user, :write)
                                end.map(&:name).to_set
      else
                                Set.new
      end

      tools.select do |tool|
        name = if tool.respond_to?(:tool_name)
                 tool.tool_name
        elsif tool.is_a?(Hash)
                 tool[:name] || tool["name"]
        else
                 nil
        end
        if dynamic_tool_names.include?(name)
          # It is a dynamic tool; user must have write permission on its creative.
          accessible_tool_names.include?(name)
        else
          # It is a system tool (not in McpTool database); allow it.
          true
        end
      end
    end

    def self.load_active_tools
      McpTool.active.find_each do |tool|
        register_tool_from_source(tool.source_code, expected_name: tool.name)
      rescue StandardError => e
        Rails.logger.error("Skipped MCP tool #{tool.name}: #{e.message}")
      end
    end

    # Fetch and filter available tools for the given user.
    # Returns an array of tool hashes with :name, :description, :params keys.
    def self.available_tools(user)
      return [] unless defined?(RailsMcpEngine)

      RailsMcpEngine::Engine.build_tools!
      result = ::Tools::MetaToolService.new.call(action: "list", tool_name: nil, query: nil, arguments: nil)
      tool_list = Array(result[:tools])
      filter_tools(tool_list, user)
    rescue StandardError => e
      Rails.logger.error("Failed to load available tools: #{e.message}")
      []
    end

    def self.delete_tool(tool_name)
      result = ::Tools::MetaToolWriteService.new.delete_tool(tool_name)

      if result[:error]
        Rails.logger.error("Failed to delete tool #{tool_name}: #{result[:error]}")
      end
    rescue StandardError => e
      Rails.logger.error("Failed to delete tool #{tool_name}: #{e.message}")
    end

    # --- Creative Parsing Logic (from MetaToolWriteService) ---

    def update_from_creative(input_creative)
      creative = input_creative.effective_origin
      return unless creative.description.present?

      # Parse HTML to find code blocks
      doc = Nokogiri::HTML.fragment(creative.description)

      # Track found tools to identify removals
      found_tool_names = []

      # Find all code blocks.
      # Lexical uses <pre class="lexical-code-block">.
      # Standard markdown often uses <code>.
      doc.css("pre.lexical-code-block, code").each do |node|
        # Create a copy to manipulate
        working_node = node.dup

        # Replace <br> tags with newlines
        working_node.search("br").each { |br| br.replace("\n") }

        code = working_node.text

        # Check if it looks like a tool definition
        if code.include?("extend ToolMeta")
          tool_name = process_tool_definition(creative, code)
          found_tool_names << tool_name if tool_name
        end
      end

      # Remove tools that are no longer in the description
      # Ensure we look at the effective origin's tools
      creative.mcp_tools.where.not(name: found_tool_names).destroy_all
    end

    private

    def process_tool_definition(input_creative, code)
      creative = input_creative.effective_origin
      # Extract tool name using regex
      tool_name_match = code.match(/tool_name\s+["'](.+?)["']/)
      return unless tool_name_match

      tool_name = tool_name_match[1]

      mcp_tool = McpTool.find_or_initialize_by(creative: creative, name: tool_name)

      # Calculate checksum to detect changes
      new_checksum = Digest::SHA256.hexdigest(code)

      if mcp_tool.new_record? || mcp_tool.checksum != new_checksum
        # Unregister old tool if it exists (source changed)
        if !mcp_tool.new_record?
          McpService.delete_tool(tool_name)
        end

        mcp_tool.source_code = code
        mcp_tool.checksum = new_checksum
        mcp_tool.approved_at = nil # Reset approval status on change

        # Extract description
        desc_match = code.match(/tool_description\s+["'](.+?)["']/)
        mcp_tool.description = desc_match[1] if desc_match

        if mcp_tool.save
          notify_approval_needed(creative, mcp_tool)
        end
      end

      tool_name
    end

    def notify_approval_needed(creative, tool)
      message = I18n.t("collavre.inbox.tool_approval_needed", tool_name: tool.name)

      # Create a comment with action payload for approval
      action_payload = {
        action: "approve_tool",
        tool_name: tool.name
      }

      Comment.create(
        creative: creative,
        content: message,
        user: nil, # System message
        approver: creative.user, # The creative owner should approve
        action: JSON.pretty_generate(action_payload),
        private: false
      )
    end
  end
end
