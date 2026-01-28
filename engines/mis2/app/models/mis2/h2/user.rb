module Mis2
  module H2
    class User < Mis2::H2Record
      self.table_name = "brain_user"
      self.primary_key = "user_idx"

      belongs_to :organization, class_name: "Mis2::H2::Organization", foreign_key: "organization_idx", optional: true
      has_many :assignment_users, class_name: "Mis2::H2::AssignmentUser", foreign_key: "user"

      scope :search_by_name, ->(name) {
        select("brain_user.*, (select brain_organization.organization_name from brain_organization where brain_user.organization_idx = brain_organization.organization_idx) as organization_name")
        .where(name: name)
      }
    end
  end
end
