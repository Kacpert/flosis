# The Designs section of a task's description (Accept designs, Kacper,
# 2026-11-21): the link to the task's designs, the merge commits on GitHub,
# and the screens they changed, new and updated, per context. Flosis writes it
# from the task's accepted copy (Designs::AcceptedScreens), never the AI, so
# its links are always right.
#
#   **Designs** · [Open the designs](<link>) · merge commit [9f3c2a1](https://github.com/<repo>/commit/<sha>)
#   - New (11): Admin › [Plans](<screen link>), … · Flosis admin › …
#   - Updated (10): Admin › [Profile Settings](…) (+3 states)
#   - Through shared components: sidebar, chat panel and 7 more
#
# It sits under the description's intro and is replaced in place by the next
# acceptance. Where a description leaves Flosis (Jira, the task's file), a
# version that lost it gets it back (with_section).
module Designs::DesignsSection
  module_function

  # The section: its first line, then its own list lines (New, Updated,
  # Through shared components), with a blank line after the first one allowed
  # (the editor's HTML, converted, puts one there). Only its own lines: the
  # description's list after a section with none is not part of it.
  OWN_LINE = "- (?:New \\(|Updated \\(|Through shared components:)[^\\n]*"
  BLOCK = /^\*\*Designs\*\* ·[^\n]*(?:\n\n?#{OWN_LINE}(?:\n#{OWN_LINE})*)?/
  KINDS = { "new" => "New", "updated" => "Updated" }.freeze
  # How many shared components the last line names before "and n more".
  SHOWN = 4

  # The section as Markdown, or nil while the task has no accepted designs.
  def build(task)
    accepted = Designs::AcceptedScreens.new(task)
    return unless accepted.any?

    publisher = Designs::Publisher.new(task.project, nil)
    key = Designs::BranchNames.slug(task)
    link = ->(screen) { publisher.url(key, "designs/#{screen[:context]}/#{screen[:screen]}.html") }
    lines = [ header(task, accepted, publisher.url(key, nil)) ]
    KINDS.each do |kind, label|
      screens = accepted.own.select { |screen| screen[:kind] == kind }
      lines << "- #{label} (#{screens.size}): #{by_context(screens, link)}" if screens.any?
    end
    names = accepted.through_names.map { |name| name.to_s.tr("-_", "  ") }
    lines << "- Through shared components: #{shared(names)}" if names.any?
    lines.join("\n")
  end

  # The text with the section in place of the one it has, else under its
  # intro: its first paragraph, or the paragraph right after a leading
  # heading.
  def insert(markdown, section)
    text = markdown.to_s.strip
    return text.sub(BLOCK) { section } if text.match?(BLOCK)

    blocks = text.split(/\n{2,}/)
    at = intro_end(blocks)
    (blocks[0...at] + [ section ] + blocks[at..].to_a).join("\n\n")
  end

  # The text as Markdown without the section: what a description says, for
  # comparing two of them (Designs::Threads.description_change).
  def strip(text)
    markdown(text).sub(BLOCK, "").gsub(/\n{3,}/, "\n\n").strip
  end

  # The text with the section, when the task has accepted designs and the
  # text lacks the link to them; otherwise the text as it is.
  def with_section(task, text)
    section = build(task) or return text
    link = Designs::Publisher.new(task.project, nil).url(Designs::BranchNames.slug(task), nil)
    # The link itself, not a longer key's that starts with it (SCRUM-700 for SCRUM-70).
    return text if text.to_s.match?(%r{#{Regexp.escape(link)}(?=[/?#)\s\]]|\z)})

    insert(markdown(text), section)
  end

  def markdown(text)
    text.to_s.lstrip.start_with?("<") ? HtmlToMarkdown.call(text) : text.to_s.strip
  end

  def header(task, accepted, overview)
    repo = task.project.design_repo.presence
    commits = accepted.merges.map do |merge|
      repo ? "[#{merge.short_sha}](https://github.com/#{repo}/commit/#{merge.sha})" : merge.short_sha
    end
    "**Designs** · [Open the designs](#{overview}) · #{commits.size == 1 ? 'merge commit' : 'merge commits'} #{commits.join(', ')}"
  end

  def by_context(screens, link)
    screens.group_by { |screen| screen[:context_name] }.map do |context, list|
      "#{context} › #{groups(list, link).join(', ')}"
    end.join(" · ")
  end

  # Screens named alike before " — " are one screen's states: the plain one
  # with a count, else the shared name once with each state linked.
  def groups(list, link)
    list.group_by { |screen| screen[:name].split(" — ", 2).first }.map do |base, members|
      plain = members.find { |screen| screen[:name] == base }
      if members.size == 1
        "[#{members.first[:name]}](#{link.call(members.first)})"
      elsif plain
        others = members.size - 1
        "[#{base}](#{link.call(plain)}) (+#{others} #{others == 1 ? 'state' : 'states'})"
      else
        "#{base} — " + members.map { |screen| "[#{screen[:name].split(' — ', 2).last}](#{link.call(screen)})" }.join(", ")
      end
    end
  end

  def shared(names)
    return names.join(", ") if names.size <= SHOWN

    "#{names.first(SHOWN).join(', ')} and #{names.size - SHOWN} more"
  end

  def intro_end(blocks)
    return 0 if blocks.empty?
    return 1 unless blocks[0].start_with?("#")

    blocks[1] && intro?(blocks[1]) ? 2 : 1
  end

  def intro?(block)
    !block.start_with?("#", "- ", "**", "|", "```", "> ", "1. ")
  end
end
