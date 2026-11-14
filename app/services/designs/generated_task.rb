# A task made from a design thread that has none (Workshop Designs v2,
# "Generate task"). The dialog's description is written from the conversation
# and the screens the thread changed, the way Kacper's design writes it; the
# person edits it, and the task starts in Details Gathering with it as its
# first version. The thread is linked to the task from then on.
module Designs::GeneratedTask
  module_function

  # changed: the thread's changed screens, as [context name, screen name].
  def draft(thread, changed:)
    asks = thread.chat_session.chat_messages.where(role: "user", kind: nil).ordered.pluck(:content)
    lines = [ "Goal: #{asks.first || thread.title}", "", "Scope, from design thread #{thread.branch}:" ]
    changed.each { |context, screen| lines << "- #{context} › #{screen}" }
    asks.drop(1).each { |ask| lines << "- #{ask}" }
    lines += [ "", "Designs: #{thread.project.design_repo} @ #{thread.branch}.",
               "", "Open questions for Details Gathering:",
               "- Empty, loading and error states the designs do not cover yet.",
               "- Which roles can see and use this?" ]
    lines.join("\n")
  end

  def create!(thread, user:, title:, description:)
    Task.transaction do
      task = thread.project.tasks.create!(name: title)
      task.enter_pipeline!(author: user, stage: "details")
      task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, content: description.presence || title, origin: "ai").make_current!
      thread.update!(task: task, described_text: Designs::CurrentDescription.for(task),
                     described_version: Designs::Threads.version_label(task))
      Designs::Threads.note(thread, "Task #{Designs::ThreadNames.key(task)} created from this thread · Details Gathering started")
      task
    end
  end
end
