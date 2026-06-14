# Extracts a Jira issue key (e.g. DEV-836) from a PR's branch, title, or body.
module PrJiraKey
  PATTERN = /\b([A-Z][A-Z0-9]+-\d+)\b/i

  def self.extract(branch:, title:, body:)
    [ branch, title, body ].compact.each do |text|
      m = text.match(PATTERN)
      return m[1].upcase if m
    end
    nil
  end
end
