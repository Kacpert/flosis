# The screens on one ref of a design repo (Workshop Designs v2). A context is a
# folder under designs/ and a screen is an .html file in it, so
# designs/admin/pipeline.html is the Pipeline screen as Admin. A screen is named
# by its <title>, else after its file; a context after its folder. What could
# not go into a link (anything but letters, digits, _ and -) is left out.
#
# paths are the repo's paths on that ref and reader reads one of them, so the
# same class reads a commit (Designs::Repo#read_file) or a test's hash.
class Designs::Screens
  ID = /\A[A-Za-z0-9_-]+\z/
  PATH = %r{\Adesigns/([^/]+)/([^/]+)\.html\z}

  attr_reader :reader

  def initialize(paths:, reader:)
    @reader = reader
    @entries = paths.filter_map do |path|
      match = PATH.match(path) or next
      context, id = match.captures
      { id: id, context: context, path: path } if ID.match?(context) && ID.match?(id)
    end.sort_by { |entry| [ entry[:context], entry[:id] ] }
  end

  def contexts
    @entries.map { |entry| entry[:context] }.uniq.map { |id| { id: id, name: id.humanize } }
  end

  def screens
    @screens ||= @entries.map { |entry| entry.merge(name: name_of(entry)) }
  end

  def find(context, id)
    screens.find { |screen| screen[:context] == context && screen[:id] == id }
  end

  # The contexts a screen of this id exists in, for "View as".
  def contexts_for(id)
    @entries.select { |entry| entry[:id] == id }.map { |entry| entry[:context] }
  end

  def html(context, id)
    entry = @entries.find { |candidate| candidate[:context] == context && candidate[:id] == id }
    entry && reader.call(entry[:path])
  end

  # What the runtime reads beside a published branch (__flosis/screens.json).
  def as_json(*)
    { contexts: contexts, screens: screens.map { |screen| screen.slice(:id, :context, :name, :path) } }
  end

  private

  def name_of(entry)
    title = Nokogiri::HTML5(reader.call(entry[:path]).to_s).at("title")&.text.to_s.squish
    title.presence || entry[:id].humanize
  end
end
