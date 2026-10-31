require "json"

# What a design repo's working tree says about itself, for the Designs screen:
# the context dimensions in designs/contexts.json and the screens in a task's
# manifest, designs/tasks/<slug>.json (Designs::Prompt::BASE has both formats).
# The tree is a task's worktree, or the clone root before the task has one.
#
# Claude writes both files, so neither is trusted. A file that is missing, is
# not JSON or is not shaped as the prompt says has nothing in it: no contexts,
# no screens, never an error. What is read is also fit to go into a link. The
# screen hands it to Designs::Publisher#url, which raises on a context that is
# not a context id (Publisher::CONTEXT) and on a page that leaves its slot, and
# a raise there would be a 500 for the whole screen. An id or a path that would
# not pass is left out here instead.
class Designs::WorkingBranch
  CONTEXTS_FILE = "designs/contexts.json".freeze

  # The page a slot opens on when the task has no screen to show first.
  INDEX = "index.html".freeze

  # The tree is a Pathname or a String. The slug is a Designs::BranchNames slug
  # (a Jira key, or task-<id>), so a file can be named after it.
  def initialize(dir, slug)
    @dir = Pathname(dir)
    @slug = slug
  end

  # The dimensions a person can switch, each as
  #   { "id", "name", "values" => [ { "id", "name" } ], "default" }
  # in the file's order. A dimension whose id is not a context id, or that has
  # no value with one, is not offered. Its default is the one the runtime
  # settles on: the file's when that is one of its values, else its first.
  def dimensions
    @dimensions ||= objects(read(CONTEXTS_FILE)["dimensions"]).filter_map { |raw| dimension(raw) }
  end

  # The value of each dimension that is active when a link names none.
  def default_ctx
    dimensions.map { |entry| entry["default"] }
  end

  # The task's screens, each as { "path", "title", "contexts" }, in the order the
  # manifest lists them. A screen is kept only when its path is under designs/,
  # exists in the tree and has no "." or ".." segment, so it is safe to link to.
  # Its contexts are the ones that are context ids.
  def screens
    @screens ||= objects(read("designs/tasks/#{@slug}.json")["screens"]).filter_map { |raw| screen(raw) }
  end

  # The page to open first: the manifest's first screen, else the repo's index.
  def entry_path
    screens.first&.fetch("path") || INDEX
  end

  private

  # The file's top-level object. {} for a file that is missing, unreadable, not
  # JSON (too deeply nested included) or not an object.
  def read(relative)
    data = JSON.parse(@dir.join(relative).read)
    data.is_a?(Hash) ? data : {}
  rescue JSON::ParserError, SystemCallError
    {}
  end

  # The objects in a list. Anything else (a list that is not one, entries that
  # are not objects) has nothing in it.
  def objects(list)
    list.is_a?(Array) ? list.grep(Hash) : []
  end

  # A string that can be matched, split and shown. JSON can carry bytes that
  # are not UTF-8 inside a string, and the first regexp to meet them raises.
  def text(value)
    value if value.is_a?(String) && value.valid_encoding?
  end

  # A name or a title, else what stands in for it, so nothing shows blank.
  def label(value, fallback)
    text(value).presence || fallback
  end

  def context_id(value)
    value if text(value)&.match?(Designs::Publisher::CONTEXT)
  end

  def dimension(raw)
    id = context_id(raw["id"])
    values = objects(raw["values"]).filter_map { |value| option(value) }
    return if id.nil? || values.empty?

    ids = values.map { |value| value["id"] }
    { "id" => id, "name" => label(raw["name"], id), "values" => values,
      "default" => ids.include?(raw["default"]) ? raw["default"] : ids.first }
  end

  def option(raw)
    id = context_id(raw["id"])
    { "id" => id, "name" => label(raw["name"], id) } if id
  end

  def screen(raw)
    path = raw["path"]
    return unless page?(path)

    contexts = raw["contexts"].is_a?(Array) ? raw["contexts"].filter_map { |value| context_id(value) } : []
    { "path" => path, "title" => label(raw["title"], path), "contexts" => contexts }
  end

  # A path under designs/ (which leaves out a leading "/" too) that has no
  # "." or ".." segment, and exists in the tree. Whole segments only: a dot in
  # a name is the name. A null byte would raise when the tree is asked.
  def page?(path)
    path = text(path)
    return false unless path&.start_with?("designs/")
    return false if path.include?("\0") || path.split("/", -1).intersect?(%w[. ..])

    @dir.join(path).exist?
  end
end
