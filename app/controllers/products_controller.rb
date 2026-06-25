# Switches the user's active product (Time & HR / Workshop). Stores the choice
# in the session (like the workspace switcher) and redirects to that product's
# landing page. Rejects products the user can't access.
class ProductsController < ApplicationController
  include WorkspaceScoped

  def switch
    product = params[:product].to_s
    if current_user.can_access_product?(current_workspace, product)
      session[:product] = product
      redirect_to product_landing_path(product.to_sym)
    else
      redirect_to product_landing_path, alert: "You don't have access to that product."
    end
  end

  # Sets the active Workshop project context (the project switcher). Only accepts
  # a project the user can actually see; redirects back to where they came from.
  def switch_project
    project = workshop_projects.find_by(id: params[:project_id])
    session[:workshop_project_id] = project.id if project
    redirect_back fallback_location: workshop_path
  end
end
