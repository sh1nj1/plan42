module Mis2
  module H2
    class Assignment < Mis2::H2Record
      self.table_name = "brain_assignment"
      self.primary_key = "assignment_idx"

      has_many :assignment_users, class_name: "Mis2::H2::AssignmentUser", foreign_key: "assignment"
    end
  end
end
