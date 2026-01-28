module Mis2
  module H2
    class Organization < Mis2::H2Record
      self.table_name = "brain_organization"
      self.primary_key = "organization_idx"

      has_many :users, class_name: "Mis2::H2::User", foreign_key: "organization_idx"
    end
  end
end
