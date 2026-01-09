require "digest"
require "set"

class McpService
  # --- Registration Logic (from MetaToolService) ---

  def self.register_tool_from_source(source_code)
    # Extract tool name for logging context
    tool_name_match = source_code.match(/tool_name\s+["'](.+?)["']/)
    tool_name = tool_name_match ? tool_name_match[1] : "unknown_tool"

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
    rescue => e
      Rails.logger.error("Failed to log tool activity: #{e.message}")
    end

    result = Tools::MetaToolWriteService.new.register_tool_from_source(
      source: source_code,
      before_call: before_call,
      after_call: after_call
    )
    puts("Registered tool: #{result}")

    if result[:error]
      error_msg = "Failed to register tool: #{result[:error]}"
      Rails.logger.error(error_msg)
      raise error_msg
    end
  rescue => e
    Rails.logger.error("Failed to register tool from source: #{e.message}")
    raise e
  end

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
    dynamic_tools = McpTool.where(name: registered_names)
    dynamic_tool_names = dynamic_tools.pluck(:name).to_set

    # If user is present, find their owned tools
    user_owned_tool_names = if user
                              dynamic_tools
                                .joins(:creative)
                                .where(creatives: { user_id: user.id })
                                .pluck(:name)
                                .to_set
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
        # It is a dynamic tool; user must own it.
        user_owned_tool_names.include?(name)
      else
        # It is a system tool (not in McpTool database); allow it.
        true
      end
    end
  end

  def self.load_active_tools
    McpTool.active.find_each do |tool|
      register_tool_from_source(tool.source_code)
    end
  end

  def self.delete_tool(tool_name)
    result = Tools::MetaToolWriteService.new.delete_tool(tool_name)

    if result[:error]
      Rails.logger.error("Failed to delete tool #{tool_name}: #{result[:error]}")
    end
  rescue => e
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
    message = I18n.t("inbox.tool_approval_needed", tool_name: tool.name)

    # Create a comment with action payload for approval
    action_payload = {
      action: "approve_tool",
      tool_name: tool.name
    }

    # TODO: user approver should be admin permission of the creative and user should be creative user.
    approver = SystemSetting.mcp_tool_approval_required? ? nil : creative.user

    Comment.create(
      creative: creative,
      content: message,
      user: nil, # System message
      approver: approver, # The creative owner should approve, or system admin if configured
      action: JSON.pretty_generate(action_payload),
      private: false
    )
  end
end
