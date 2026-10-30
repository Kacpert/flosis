# What may reach a client's design repo. The Committer shows the guard what a
# turn staged, and one violation throws the whole turn away. Three things stay
# out of a client's repo: files that are not design files, passages of the
# Flosis library (its prompts and skills are Flosis's own work) and the
# credentials Flosis stores.
#
# A violation names the path and the rule, never the text that broke it:
# violations are reported to the people using the project, and quoting a
# passage or a credential there would leak it a second time.
class Designs::LeakGuard
  ALLOWED_FILES = %w[README.md index.html].freeze
  ALLOWED_DIRS = %w[design_system/ components/ designs/ runtime/].freeze

  # Git's own configuration files, in any folder and in any case (a
  # case-insensitive filesystem reads .GitAttributes as .gitattributes). None
  # is a design file, and a .gitattributes inside an allowed folder can route
  # content through a filter (LFS) that moves it past the diff the guard reads.
  GIT_CONFIG_FILES = %w[.gitattributes .gitmodules .gitignore].freeze

  # Twelve words in a row, shared with a forbidden text, are a passage of it:
  # fewer would catch phrases that any design may use.
  PASSAGE_WORDS = 12

  # A shorter secret would turn up by chance in ordinary text.
  MIN_SECRET_LENGTH = 8

  OUTSIDE_FOLDERS = "is outside the design repo's allowed folders".freeze
  LIBRARY_PASSAGE = "contains a passage from the Flosis library".freeze
  STORED_CREDENTIAL = "contains a stored credential".freeze

  # Shown in place of a path that has a credential in it.
  WITHHELD = "[withheld]".freeze

  Violation = Data.define(:path, :reason)

  # forbidden_texts: the library texts that no design may quote. secrets: the
  # credentials stored for the project; nil, blank and short ones are ignored.
  def initialize(forbidden_texts: [], secrets: [])
    @passages = Set.new
    Array(forbidden_texts).each { |text| @passages.merge(runs(text)) }
    @secrets = Array(secrets).map { |secret| secret.to_s.strip }
                             .select { |secret| secret.length >= MIN_SECRET_LENGTH }.uniq
  end

  # A violation for each rule a change breaks, in the order of the rules.
  def check(changes)
    changes.flat_map { |change| violations_for(change) }
  end

  # How much the guard holds, never what. The default inspect lists every
  # instance variable, so a log line, an exception, a console or a failed
  # assertion that printed the guard (or a Committer holding it) would repeat
  # every credential and library passage in it. pp prints this too.
  def inspect
    "#<#{self.class} secrets=#{@secrets.size} passages=#{@passages.size}>"
  end

  private

  def violations_for(change)
    path = change.path.to_s.scrub
    text = change.added_text.to_s
    in_path = credential?(path)

    reasons = []
    reasons << OUTSIDE_FOLDERS unless design_path?(path)
    reasons << LIBRARY_PASSAGE if passage?(text)
    reasons << STORED_CREDENTIAL if in_path || credential?(text)
    reasons.map { |reason| Violation.new(path: in_path ? WITHHELD : path, reason: reason) }
  end

  # Paths come from git: relative to the repo, and never with "." or ".." in
  # them. Any other spelling is refused rather than resolved, so a folder's
  # prefix cannot be walked out of ("designs/../CLAUDE.md").
  def design_path?(path)
    segments = path.split("/", -1)
    return false if segments.empty? || segments.any? { |segment| segment.empty? || %w[. ..].include?(segment) }
    return false if GIT_CONFIG_FILES.include?(segments.last.downcase)

    ALLOWED_FILES.include?(path) || path.start_with?(*ALLOWED_DIRS)
  end

  def passage?(text)
    @passages.any? && runs(text).any? { |run| @passages.include?(run) }
  end

  def credential?(text)
    @secrets.any? { |secret| text.include?(secret) }
  end

  # Every run of PASSAGE_WORDS consecutive words in the text, each as one
  # string, so that only the words count: case, spacing and punctuation do not.
  def runs(text)
    text.to_s.scrub.downcase.scan(/[[:alnum:]]+/).each_cons(PASSAGE_WORDS).lazy.map { |words| words.join(" ") }
  end
end
