# The Designs setup form's saving (Workshop Designs v2): the stack, the designs
# repository and its token, the app's repositories and the contexts with their
# logins. The setup (Build designs, Save and re-import) and New import (Kacper,
# 2026-11-22: "nie powinien od razu odpalać importu tylko dać formularz") save
# through it, so that both refuse the same things in the same words.
#
# Any GitHub address names its repository, as on the project: "github.com/
# acme/designs", "git@github.com:acme/designs.git" and "acme/designs" all name
# acme/designs, and "acme/app@production" keeps its branch. A context's saved
# password stays when the form leaves it blank; a new context needs one.
class Designs::SetupForm
  SUPPORTED = %w[html tailwind custom].freeze
  INCOMPLETE = "Fill in the designs repository, at least one app repository and one context: its URL and login, or No login.".freeze
  REPO = %r{\A[\w.-]+/[\w.-]+(@[\w./-]+)?\z}

  # Why the form was refused: INCOMPLETE, or what the record refused.
  attr_reader :error

  # params: the form's permitted parameters.
  def initialize(project, params)
    @project = project
    @params = params
  end

  def save
    repo = repo_name(@params[:repo])
    repos = rows(@params[:repos]).filter_map do |row|
      name = repo_name(row[:url])
      { "role" => row[:role].to_s.strip.presence || "Repository", "repo" => name } if name&.match?(REPO)
    end
    contexts = rows(@params[:contexts]).select { |row| row[:name].present? && (code_only?(row) || (row[:url].present? && row[:login].present?)) }
    roles = @project.design_setup_roles.index_by { |role| role.id.to_s }
    return incomplete unless repo&.match?(REPO) && repos.any? && contexts.any?
    return incomplete if contexts.any? { |row| !code_only?(row) && row[:password].blank? && !(roles[row[:id].to_s]&.password.present?) }

    save!(repo, repos, contexts, roles)
    true
  rescue ActiveRecord::RecordInvalid => e
    # What only the record can judge (the target being one of the app's own
    # repositories) is said on the form; it used to escape as a bare 422.
    @error = e.record.errors.full_messages.to_sentence
    false
  end

  private

  def save!(repo, repos, contexts, roles)
    framework = @params[:framework].presence_in(SUPPORTED) || "html"
    ui = @params[:ui].presence_in(SUPPORTED) || "tailwind"
    Project.transaction do
      @project.update!(designs_framework: framework, designs_framework_version: @params[:framework_version].presence,
                       designs_ui_system: ui, designs_ui_version: @params[:ui_version].presence, design_repo: repo,
                       design_app_repos: repos, design_base_kit: ui == "custom" ? "plain" : "tailwind4",
                       design_app_url: origin(contexts.find { |row| row[:url].present? }&.dig(:url)) || @project.design_app_url, designs_enabled: true)
      @project.update!(design_repo_token: @params[:repo_token]) if @params[:repo_token].present?
      kept = contexts.each_with_index.map do |row, position|
        role = roles[row[:id].to_s] || @project.design_setup_roles.new
        if code_only?(row)
          # No login (Kacper, 2026-11-22): built from the code; whatever
          # login it had goes.
          role.assign_attributes(name: row[:name].strip, code_only: true, login_url: nil, username: nil, password: nil, position: position)
        else
          role.assign_attributes(name: row[:name].strip, code_only: false, login_url: row[:url].strip, username: row[:login].strip, position: position)
          role.password = row[:password] if row[:password].present?
        end
        role.save!
        role.id
      end
      @project.design_setup_roles.where.not(id: kept).destroy_all
    end
  end

  def incomplete
    @error = INCOMPLETE
    false
  end

  def code_only?(row) = ActiveModel::Type::Boolean.new.cast(row[:code_only]) || false

  def repo_name(value)
    Project.normalize_value_for(:github_repo, value.to_s).presence
  end

  def rows(value)
    value.respond_to?(:values) ? value.values : Array(value)
  end

  def origin(url)
    uri = URI.parse(url.to_s.strip)
    uri.host ? "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.default_port == uri.port}" : url
  rescue URI::InvalidURIError
    url
  end
end
