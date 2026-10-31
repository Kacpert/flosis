# One approval of a task's designs: its working branch merged into master, and
# the tag that marks that moment. Designs::Approval writes it once and nothing
# changes it, so there is a created_at and no updated_at.
#
# number counts the task's approvals from 1 and is the last segment of the tag
# (approved/<KEY>/<number>); the database allows each number once per task.
# design_sha is the commit of the working branch that was approved, the one
# the task's design branch now points at, and master_sha is master after that
# work was merged into it, where the tag points.
class DesignApproval < ApplicationRecord
  belongs_to :task
  belongs_to :user
end
