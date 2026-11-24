# Saving an integration asks it at once whether it works (Kacper, 2026-11-24),
# so a test answers for Jira, GitHub and Figma instead of reaching them.
module IntegrationHealthTestHelper
  CLIENTS = { jira: JiraClient, github: GithubClient, figma: FigmaClient }.freeze

  def answer_health_checks(answers = {})
    @health_check_originals ||= CLIENTS.values.to_h { |client| [ client, client.instance_method(:health_check) ] }
    CLIENTS.each do |name, client|
      answer = answers.fetch(name, { ok: true })
      client.define_method(:health_check) { answer }
    end
  end

  def restore_health_checks
    @health_check_originals&.each { |client, original| client.define_method(:health_check, original) }
  end
end
