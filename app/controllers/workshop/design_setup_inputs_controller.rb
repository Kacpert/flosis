# The inputs of the current project's setup run, for Flosis staff: the app's
# URL, the Figma files, uploaded materials and the roles to crawl the app as.
# Role passwords are write-only: a blank one keeps the stored password.
class Workshop::DesignSetupInputsController < Workshop::BaseController
  include FlosisStaffOnly

  def update
    attrs = params.require(:project).permit(:design_app_url, :design_figma_urls, design_materials: [])
    project.design_app_url = attrs[:design_app_url] if attrs.key?(:design_app_url)
    if attrs.key?(:design_figma_urls)
      project.design_figma_urls = attrs[:design_figma_urls].to_s.lines.map(&:strip).reject(&:empty?)
    end
    project.design_materials.attach(attrs[:design_materials]) if attrs[:design_materials].present?
    done(project.save, "Setup inputs saved", project)
  end

  def add_role
    role = project.design_setup_roles.new(role_params)
    role.position = project.design_setup_roles.maximum(:position).to_i + 1
    done(role.save, "#{role.name} added", role)
  end

  def update_role
    role = project.design_setup_roles.find(params[:id])
    attrs = role_params
    attrs.delete(:password) if attrs[:password].blank?
    done(role.update(attrs), "#{role.name} saved", role)
  end

  def remove_role
    role = project.design_setup_roles.find(params[:id])
    role.destroy!
    done(true, "#{role.name} removed", role)
  end

  def remove_material
    material = project.design_materials.find(params[:attachment_id])
    material.purge
    done(true, "#{material.filename} removed", project)
  end

  private

  def project
    current_workshop_project
  end

  def role_params
    params.require(:role).permit(:name, :login_url, :username, :password, :notes)
  end

  def done(saved, toast, record)
    if saved
      flash[:clar_toast] = toast
    else
      flash[:alert] = record.errors.full_messages.to_sentence
    end
    redirect_to workshop_configuration_path(tab: "designs"), status: :see_other
  end
end
