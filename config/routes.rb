Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token

  resource :registration, only: [ :new, :create ]

  resources :workspaces, only: [ :new, :create ] do
    member do
      post :switch
    end
  end

  # Workspace-scoped routes
  root "time_entries#index"

  resource :profile, only: [ :show, :update ]
  resources :workspace_members, only: [ :index, :new, :create, :edit, :update, :destroy ]

  resources :clients
  resources :projects do
    resources :tasks, only: [ :create, :destroy ], shallow: true
    member do
      patch :archive
      patch :unarchive
      get :jira_tasks, to: "jira#jira_tasks"
      post :jira_sync, to: "jira#sync"
    end
  end
  resources :tags

  resources :time_entries do
    collection do
      post :bulk_update
      post :bulk_destroy
    end
  end

  resource :timer, only: [] do
    post :start
    patch :stop
    patch :update_running
    delete :discard
  end

  resource :timesheet, only: [ :show ] do
    patch :update_cell
  end

  namespace :reports do
    resource :summary, only: [ :show ] do
      get :export_csv
      get :export_pdf
    end
    resource :detailed, only: [ :show ] do
      get :export_csv
      get :export_pdf
    end
    resource :weekly, only: [ :show ] do
      get :export_csv
      get :export_pdf
    end
  end

  # API endpoints for dynamic UI
  get "projects/:project_id/tasks_list", to: "tasks#list", as: :project_tasks_list

  # Jira integration
  get "jira/projects", to: "jira#projects", as: :jira_projects

  get "up" => "rails/health#show", as: :rails_health_check
end
