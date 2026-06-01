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
  resources :workspace_members, only: [ :index, :new, :create, :edit, :update, :destroy ] do
    member do
      post :become
    end
  end
  post :stop_impersonating, to: "workspace_members#stop_impersonating"

  resources :clients
  resources :feedback_meetings
  resources :projects do
    resources :tasks, only: [ :create, :destroy ], shallow: true
    resources :project_memberships, only: [ :create, :update, :destroy ], path: "members"
    member do
      patch :archive
      patch :unarchive
      get :jira_tasks, to: "jira#jira_tasks"
      post :jira_sync, to: "jira#sync"
    end
  end
  resources :tags

  resources :holiday_requests, only: [:index, :new, :create] do
    member do
      patch :approve
      patch :cancel
    end
  end

  resources :holiday_balance_entries, only: [:index, :new, :create]

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
    get :month
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

  resources :jira_tasks, only: [:index, :show] do
    collection do
      get :board_data
      post :refresh
    end
    resources :task_drafts, only: [:index]
    resource :chat_session, only: [:create, :show, :destroy] do
      post :message
    end

    # Estimate & breakdown: two-panel page + its own chat + versioned results
    get :breakdown, to: "task_breakdowns#show"
    resources :task_breakdowns, only: [:index]
    resource :breakdown_chat_session, only: [:create, :show, :destroy] do
      post :message
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
