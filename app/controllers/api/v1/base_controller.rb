# The JSON API, authenticated by a personal access token (ApiToken) in
# `Authorization: Bearer gold_pat_…`. No cookies, no CSRF, no browser gate: it
# is for scripts and other AIs, and a token only ever reaches what its scopes
# name, as the person who holds it, in the workspace it was issued for.
module Api
  module V1
    class BaseController < ActionController::API
      include ActionController::HttpAuthentication::Token::ControllerMethods

      wrap_parameters false

      before_action :authenticate_token!

      rate_limit to: 120, within: 1.minute,
                 by: -> { request.authorization.to_s.presence || request.remote_ip },
                 with: -> { render_error(:too_many_requests, "Too many requests, slow down (120 per minute).") }

      rescue_from ActionController::ParameterMissing do |error|
        render_error(:bad_request, error.message)
      end

      private

      attr_reader :api_token

      def api_user
        api_token.user
      end

      def api_workspace
        api_token.workspace
      end

      # The person is checked again on every request: someone who has since
      # lost the workspace or its Time & HR access loses the token with it.
      def authenticate_token!
        @api_token = authenticate_with_http_token { |raw, _options| ApiToken.authenticate(raw) }
        return render_error(:unauthorized, "Missing, invalid, expired or revoked API token.") unless @api_token
        return render_error(:forbidden, "This account has no Time & HR access in the token's workspace.") unless api_user.can_access_time_hr?(api_workspace)

        @api_token.touch_last_used!
      end

      def require_scope!(scope)
        render_error(:forbidden, "This token does not allow #{scope}.") unless api_token.allows?(scope)
      end

      # The same projects the Time & HR screens offer this person
      # (WorkspaceScoped#available_projects): every active one for a workspace
      # admin, otherwise the active projects they are a member of.
      def bookable_projects
        scope = api_workspace.projects.active
        unless api_user.workspace_admin?(api_workspace)
          scope = scope.joins(:project_memberships).where(project_memberships: { user_id: api_user.id })
        end
        scope.order(:name)
      end

      def render_error(status, message, details: nil)
        body = { error: message }
        body[:details] = details if details
        render json: body, status: status
      end
    end
  end
end
