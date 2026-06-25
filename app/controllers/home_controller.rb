# Root entry point: send the user to their current product's landing page.
class HomeController < ApplicationController
  include WorkspaceScoped

  def index
    redirect_to product_landing_path
  end
end
