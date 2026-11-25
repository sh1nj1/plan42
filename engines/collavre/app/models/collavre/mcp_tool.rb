module Collavre
  class McpTool < ApplicationRecord
    self.table_name = "mcp_tools"

    belongs_to :creative, class_name: "Collavre::Creative"

    validates :name, presence: true, uniqueness: true
    validates :source_code, presence: true

    after_destroy :unregister_tool

    scope :active, -> { where.not(approved_at: nil) }

    def active?
      approved_at.present?
    end

    def requires_approval?
      requires_approval == true
    end

    # Arbitrary constant naming the PostgreSQL advisory lock for approvals.
    APPROVAL_LOCK_KEY = 0x6d63_7074

    # Approval checks the constants of tools already approved on other server
    # processes (see McpToolRegistrar.approved_conflict). The check and the
    # approved_at write must be one step across processes, or two colliding
    # approvals both see no conflict. PostgreSQL takes an advisory lock for the
    # transaction; SQLite transactions begin IMMEDIATE and so already hold the
    # database write lock.
    def self.serialize_approvals
      transaction do
        connection.execute("SELECT pg_advisory_xact_lock(#{APPROVAL_LOCK_KEY})") if connection.adapter_name == "PostgreSQL"
        yield
      end
    end

    def approve!
      self.class.serialize_approvals do
        # Register the tool immediately upon approval
        ::McpService.register_tool_from_source(source_code, expected_name: name)
        # This transaction may be joined to a caller's (the approval comment's
        # action executor). If approved_at is rolled back, here or later in that
        # outer transaction, the tool must not stay discoverable here.
        self.class.current_transaction.after_rollback { ::McpService.delete_tool(name) }
        update!(approved_at: Time.current)
      end
    end

    private

    def unregister_tool
      ::McpService.delete_tool(name)
    end
  end
end
