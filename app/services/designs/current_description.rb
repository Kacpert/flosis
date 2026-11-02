# What Claude designs from: the description the person has worked on furthest.
# That is the task's current refined description (the Details draft), else its
# current brief, else the ticket's own description. nil when nothing has been
# written yet. An estimate breakdown is not a description and never counts.
module Designs::CurrentDescription
  module_function

  def for(task)
    task.current_detail_draft&.content.presence ||
      task.current_brief&.content.presence ||
      task.description.presence
  end
end
