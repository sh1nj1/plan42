module Collavre
  require "monitor"

  # Registers an approved McpTool's source so that exactly the class it
  # declares becomes a tool under the recorded name, and a failed approval
  # leaves nothing behind.
  class McpToolRegistrar
    # ToolMeta.registry is process-wide. Evaluating a source and rolling back
    # what it added must not interleave with another registration, or one
    # approval's rollback removes the class the other just registered.
    REGISTRY_LOCK = Monitor.new

    # Evaluating a source reopens an existing class, so a tool may only reuse a
    # constant it defined itself (re-approval after an edit, or a retry). The
    # owner is stored on the class, not in this reloadable service, so it
    # survives a development reload for as long as the class does.
    OWNER_IVAR = :@collavre_mcp_tool_owner

    def self.synchronize(&block)
      REGISTRY_LOCK.synchronize(&block)
    end

    # The service constant goes too when this tool defined it, so another tool
    # can use the class name once this one is gone.
    def self.delete(tool_name)
      synchronize do
        service_class = ::Tools::MetaToolService.new.find_schema(tool_name)&.dig(:service_class)
        deleted = ::Tools::MetaToolWriteService.new.delete_tool(tool_name)
        remove_constant(service_class.name) if owner_of(service_class) == tool_name
        deleted
      end
    end

    # Same steps as MetaToolWriteService#register_tool_from_source, with a name
    # check between evaluating the source and building the tool classes.
    # Every constant the approval would write is checked first, so nothing it
    # removes on failure can belong to another tool or the application. A failed
    # approval therefore removes the service constant too; left behind with an
    # owner mark, it would block every later tool using the same class name.
    def self.register(writer, source_code, expected_name, before_call:, after_call:)
      class_name = writer.send(:extract_class_name, source_code)
      return { error: "class_name is required for register" } if class_name.blank?

      conflict = constant_conflict(class_name, expected_name) || approved_conflict(writer, class_name, expected_name)
      return { error: conflict } if conflict

      service_class = evaluate_keeping_only_verified(source_code, class_name, expected_name)
      result = service_class.is_a?(Class) ? register_or_roll_back(writer, service_class, class_name, before_call: before_call, after_call: after_call) : service_class
      remove_tool_constants(class_name) if result[:error]
      result
    end

    # A tool may only reuse a service constant it defined itself (re-approval
    # after an edit, or a retry). The factories also write Tools::<Base> and
    # Mcp::<Base>, <Base> being the class name without its Service suffix, so
    # those must not belong to anyone else either.
    def self.constant_conflict(class_name, expected_name)
      existing = class_name.safe_constantize
      return "#{class_name} is already defined by another tool or the application; rename the class" if existing && owner_of(existing) != expected_name

      generated = generated_constants(class_name)
      taken = generated.find { |name| name == class_name || generated_constant_taken?(name, existing) }
      "#{class_name} builds #{taken}, which another tool or the application already defines; rename the class" if taken
    end
    private_class_method :constant_conflict

    # The checks above only see this process. Another worker may have approved
    # a tool on the same constants, so the recorded sources of approved tools
    # are checked too. The earlier approval wins, which is also the order
    # load_active_tools keeps when both are loaded after a restart.
    def self.approved_conflict(writer, class_name, expected_name)
      claimed = [ class_name, *generated_constants(class_name) ]
      earlier_approved(expected_name).find_each do |tool|
        other = writer.send(:extract_class_name, tool.source_code)
        next if other.blank?

        taken = ([ other, *generated_constants(other) ] & claimed).first
        return "#{class_name} uses #{taken}, which another approved tool already uses; rename the class" if taken
      end
      nil
    end
    private_class_method :approved_conflict

    def self.earlier_approved(expected_name)
      approved_at = McpTool.where(name: expected_name).pick(:approved_at)
      others = McpTool.active.where.not(name: expected_name)
      return others unless approved_at

      others.where("approved_at < :at", at: approved_at)
    end
    private_class_method :earlier_approved

    def self.generated_constants(class_name)
      base = class_name.demodulize.delete_suffix("Service")
      [ "Tools::#{base}", "Mcp::#{base}" ]
    end
    private_class_method :generated_constants

    # Taken when another registered service builds the same constant, or when
    # it is already defined and this tool has no class that built it earlier.
    def self.generated_constant_taken?(name, existing)
      namespace, constant = name.split("::")
      built_by_other = ToolMeta.registry.any? do |klass|
        !klass.equal?(existing) && klass.name && generated_constants(klass.name).include?(name)
      end
      built_by_other || (existing.nil? && namespace.constantize.const_defined?(constant, false))
    end
    private_class_method :generated_constant_taken?

    # Evaluating the source adds every class that extends ToolMeta to the
    # registry, even when the class body raises afterwards. Only the verified
    # service class may stay; everything else the source added is rolled back.
    # A class this tool defined earlier is taken out of the registry first, so
    # the source must extend ToolMeta on it again; its old metadata cannot pass.
    def self.evaluate_keeping_only_verified(source_code, class_name, expected_name)
      existing = class_name.safe_constantize
      ToolMeta.registry.delete(existing) if existing
      registered_before = ToolMeta.registry.dup
      keep = nil
      begin
        result = evaluate_and_verify(source_code, class_name, expected_name)
        result = mark_owner(result, expected_name) if result.is_a?(Class)
        keep = result if result.is_a?(Class)
      ensure
        ToolMeta.registry.reject! { |klass| !registered_before.include?(klass) && !klass.equal?(keep) }
      end
      result
    end
    private_class_method :evaluate_keeping_only_verified

    # A class the source froze cannot take the owner mark, so it is not approved.
    def self.mark_owner(service_class, expected_name)
      service_class.instance_variable_set(OWNER_IVAR, expected_name)
      service_class
    rescue FrozenError => e
      { error: "Failed to record the owner of #{service_class.name}: #{e.message}" }
    end
    private_class_method :mark_owner

    # A failed evaluation must not leave the generated constants of an earlier
    # approval behind either: without their service class they would read as
    # another tool's, and the next load would refuse this tool for good.
    def self.remove_tool_constants(class_name)
      [ *generated_constants(class_name), class_name ].each { |name| remove_constant(name) }
    end
    private_class_method :remove_tool_constants

    def self.remove_constant(class_name)
      namespace = class_name.deconstantize.presence&.safe_constantize || Object
      constant = class_name.demodulize
      namespace.send(:remove_const, constant) if namespace.const_defined?(constant, false)
    end
    private_class_method :remove_constant

    def self.owner_of(klass)
      klass.instance_variable_get(OWNER_IVAR) if klass.is_a?(Module)
    end
    private_class_method :owner_of

    # Building the tool classes can still fail (e.g. a sig that yields no
    # schema). The verified class must then leave the registry too, or the
    # unapproved tool stays discoverable through MetaToolService.
    def self.register_or_roll_back(writer, service_class, class_name, before_call:, after_call:)
      result = writer.register_tool(class_name, before_call: before_call, after_call: after_call)
      roll_back_registration(service_class) if result[:error]
      result
    rescue StandardError, ScriptError => e
      roll_back_registration(service_class)
      { error: "Failed to register #{class_name}: #{e.message}" }
    end
    private_class_method :register_or_roll_back

    def self.roll_back_registration(service_class)
      ToolMeta.registry.delete(service_class)
      { ::Tools => ToolSchema::RubyLlmFactory, ::Mcp => ToolSchema::FastMcpFactory }.each do |namespace, factory|
        constant = factory.tool_class_name(service_class)
        namespace.send(:remove_const, constant) if namespace.const_defined?(constant, false)
      end
    end
    private_class_method :roll_back_registration

    # A source that raises between a sig and its def leaves that sig pending on
    # the thread, and Sorbet would fail every later evaluation on it with
    # "You called sig twice".
    def self.discard_pending_sig
      T::Private::DeclState.current.reset! if defined?(T::Private::DeclState)
    end
    private_class_method :discard_pending_sig

    # Returns the service class when this evaluation extended it with ToolMeta
    # and it declares expected_name, else an error hash.
    def self.evaluate_and_verify(source_code, class_name, expected_name)
      begin
        Object.class_eval(source_code)
      rescue StandardError, ScriptError => e
        discard_pending_sig
        return { error: "Failed to evaluate source: #{e.message}" }
      end

      service_class = class_name.safe_constantize
      return { error: "#{class_name} is not defined by the source" } unless service_class.is_a?(Class)
      return { error: "#{class_name} does not extend ToolMeta in the source" } unless ToolMeta.registry.include?(service_class)

      declared = service_class.instance_variable_get(:@tool_name)
      return service_class if declared == expected_name

      ToolMeta.registry.delete(service_class)
      { error: "#{class_name} declares tool_name #{declared.inspect}, expected #{expected_name.inspect}" }
    end
    private_class_method :evaluate_and_verify
  end
end
