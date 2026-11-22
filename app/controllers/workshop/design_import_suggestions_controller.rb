# Feedback on an import's page (Kacper, 2026-11-22): what the person does
# with what the import needed from them. A role the setup lacked is added,
# with its login or code-only, and its screens imported (Designs::ImportMore);
# a context that could not sign in gets its login fixed and what was built
# from the code for it checked again; anything can be dismissed, and a
# dismissed role is not raised again. Only on an import that is over: one
# that stopped is resumed first.
class Workshop::DesignImportSuggestionsController < Workshop::BaseController
  before_action { require_permission!(:designs) }
  before_action { require_permission!(:configuration) }
  include DesignsVisibility
  before_action :load_suggestion
  before_action :refuse_unless_open, except: :dismiss

  INCOMPLETE = "Fill in the login URL, the login and the password.".freeze

  def from_code
    role = context_role
    role.update!(code_only: true, login_url: nil, username: nil, password: nil) unless role.persisted? && role.signs_in?
    Designs::ImportMore.new(@import).context!(role, @suggestion)
    @suggestion.act!(current_user, "done")
    back("Importing #{role.name} from the code")
  end

  def add_login
    return back(INCOMPLETE) unless login_given?

    role = context_role
    role.assign_attributes(code_only: false, login_url: params[:login_url].to_s.strip, username: params[:login].to_s.strip)
    role.password = params[:password]
    return back(role.errors.full_messages.to_sentence) unless role.save

    Designs::ImportMore.new(@import).context!(role, @suggestion)
    @suggestion.act!(current_user, "done")
    back("Importing #{role.name}")
  end

  def fix_login
    role = @suggestion.role or return back("That context is no longer in the setup.")
    return back(INCOMPLETE) unless login_given?

    role.assign_attributes(code_only: false, login_url: params[:login_url].to_s.strip, username: params[:login].to_s.strip)
    role.password = params[:password]
    return back(role.errors.full_messages.to_sentence) unless role.save

    queued = Designs::ImportMore.new(@import).fix_login!(role)
    @suggestion.act!(current_user, "done")
    back(queued.any? ? "Checking #{role.name} against the app" : "Login saved. Nothing of this import was built from the code for #{role.name}.")
  end

  def dismiss
    @suggestion.act!(current_user, "dismissed") if @suggestion.status == "open"
    back("Dismissed")
  end

  private

  def load_suggestion
    @import = current_workshop_project.design_setups.where.not(kind: "reimport").find(params[:design_import_id])
    @suggestion = @import.suggestions.find(params[:id])
  end

  def refuse_unless_open
    if @suggestion.status != "open"
      back("This one is settled already.")
    elsif !@import.done? || @import.running?
      back("Resume the import first: it imports more once it is over.")
    end
  end

  def login_given? = params[:login_url].present? && params[:login].present? && params[:password].present?

  # The setup's context of the suggestion's name, or a new one, last.
  def context_role
    name = @suggestion.context_name.presence || @suggestion.title
    current_workshop_project.design_setup_roles.find_by(name: name) ||
      current_workshop_project.design_setup_roles.new(name: name, position: current_workshop_project.design_setup_roles.maximum(:position).to_i + 1)
  end

  def back(toast)
    flash[:clar_toast] = toast
    redirect_to helpers.import_page_path(@import)
  end
end
