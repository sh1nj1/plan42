module Mis2
  module H3
    class OrganizationAdmin < Mis2::H3Record
      self.table_name = "organization_admin"
      self.ignored_columns = %w[password]

      STATUSES = %w[WAIT ACTIVE INACTIVE DELETED].freeze

      belongs_to :department,
        class_name: "Mis2::H3::OrganizationDepartment",
        foreign_key: "organization_department_id"

      has_one :organization, through: :department

      scope :organization_admins, -> { where(role: "ORGANIZATION_ADMIN") }

      scope :with_org_details, -> {
        joins(department: :organization)
          .select(
            "organization_admin.*",
            "organization_department.medical_specialty",
            "organization.name AS org_name",
            "organization.code AS org_code",
            "organization.type AS org_type"
          )
      }

      scope :filter_by_statuses, ->(statuses) {
        where(status: Array(statuses)) if statuses.present?
      }

      scope :search_by_org, ->(query) {
        if query.present?
          where(
            "LOWER(organization.name) LIKE LOWER(:q) OR LOWER(organization.code) LIKE LOWER(:q)",
            q: "%#{sanitize_sql_like(query)}%"
          )
        end
      }
    end
  end
end
