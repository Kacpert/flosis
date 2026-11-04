module Api
  module V1
    class ProjectsController < BaseController
      before_action { require_scope!("projects:read") }

      def index
        projects = bookable_projects.includes(:client)
        render json: { projects: projects.map { |project| serialize(project) } }
      end

      private

      def serialize(project)
        {
          id: project.id,
          name: project.name,
          client: project.client&.name,
          jira_key: project.external_type == "jira" ? project.external_reference : nil,
          color: project.color
        }
      end
    end
  end
end
