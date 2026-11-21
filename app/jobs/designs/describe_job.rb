# Writes a task's next description version from its accepted designs
# (2026-11-21). Task 5 of the plan fills this in.
class Designs::DescribeJob < ApplicationJob
  queue_as :designs

  def perform(turn_id); end
end
