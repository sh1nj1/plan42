module Mis2
  module H3
    class OrganizationDepartment < Mis2::H3Record
      self.table_name = "organization_department"

      belongs_to :organization,
        class_name: "Mis2::H3::Organization",
        foreign_key: "organization_id"

      has_many :admins,
        class_name: "Mis2::H3::OrganizationAdmin",
        foreign_key: "organization_department_id"
    end
  end
end
