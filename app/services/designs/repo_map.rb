# The design repo as a thread's turn starts, given to Claude with the request
# (2026-11-10), so that it reads only what it needs instead of mapping the
# repo first: SCRUM-70's first turn spent minutes on that. The kit, every
# screen of every context by its title, every component by the first line of
# its guidelines, and, when full, the theme and the screen the person has
# open, whole. A session's later turns get the list alone: the rest is in the
# conversation already, and would only make it longer.
#
# Nothing outside the worktree is read, whatever a link in it points at.
module Designs::RepoMap
  # Past these, a file is left for Claude to read itself.
  THEME_LIMIT = 40_000
  SCREEN_LIMIT = 60_000
  # A screen's <title> is near its top.
  HEAD_BYTES = 8_192

  module_function

  def text(worktree, focus: nil, full: false)
    root = Pathname(worktree)
    parts = [ "Kit: #{kit(root)}",
              "### Screens\n#{screens(root).presence || "(none yet)"}",
              "### Components\n#{components(root).presence || "(none yet)"}" ]
    if full
      parts << whole(root, "design-system/theme.css", "css", THEME_LIMIT)
      parts << whole(root, focus, "html", SCREEN_LIMIT, heading: "The screen the person has open: #{focus}") if focus
    end
    parts.compact.join("\n\n")
  end

  def kit(root)
    path = root.join("runtime/config.json")
    config = path.file? && inside?(root, path) && JSON.parse(path.read)
    (config.is_a?(Hash) && config["kit"].presence) || "unknown"
  rescue JSON::ParserError, SystemCallError
    "unknown"
  end

  def screens(root)
    root.glob("designs/*/*.html").select { |path| path.file? && inside?(root, path) }.sort.map do |path|
      head = File.read(path, HEAD_BYTES).to_s.force_encoding(Encoding::UTF_8).scrub
      title = Nokogiri::HTML5(head).at("title")&.text.to_s.squish
      "- #{path.relative_path_from(root)} — #{title.presence || path.basename(".html").to_s.humanize}"
    end.join("\n")
  end

  def components(root)
    root.glob("components/*/").select { |dir| inside?(root, dir) }.sort.map do |dir|
      line = guideline(root, dir.join("README.md"))
      "- components/#{dir.basename}/#{" — #{line}" if line.present?}"
    end.join("\n")
  end

  # The first line of a component's README that is not a heading.
  def guideline(root, readme)
    return unless readme.file? && inside?(root, readme)

    File.foreach(readme).lazy.map { |line| line.scrub.strip }.reject { |line| line.empty? || line.start_with?("#") }.first.to_s.truncate(140)
  end

  def whole(root, relative, fence, limit, heading: relative)
    path = root.join(relative.to_s)
    return unless path.file? && inside?(root, path)
    return "### #{heading}\n(too big to give here: read it yourself)" if path.size > limit

    "### #{heading}\n```#{fence}\n#{path.read.scrub.chomp}\n```"
  end

  # A file, or a folder, in the worktree itself: not a link, and not under a
  # folder that is a link out of it.
  def inside?(root, path)
    return false if path.symlink? || !path.exist?

    path.realpath.to_s.start_with?("#{root.realpath}/")
  rescue SystemCallError
    false
  end
end
