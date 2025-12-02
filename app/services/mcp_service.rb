class McpService
  # --- Registration Logic (from MetaToolService) ---

  def self.register_tool_from_source(source_code)
    # Use the engine's service to register the tool
    # Note: We use Tools::MetaToolWriteService from rails_mcp_engine
    result = Tools::MetaToolWriteService.new.register_tool_from_source(source: source_code)

    if result[:error]
      error_msg = "Failed to register tool: #{result[:error]}"
      Rails.logger.error(error_msg)
      raise error_msg
    end
  rescue => e
    Rails.logger.error("Failed to register tool from source: #{e.message}")
    raise e
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
