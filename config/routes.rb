Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token

  resource :registration, only: [ :new, :create ]

  resources :workspaces, only: [ :new, :create ] do
    member do
      post :switch
    end
  end

  # Workspace-scoped routes. Root redirects to the current product's landing.
  root "home#index"

  post "product/switch", to: "products#switch", as: :switch_product
  post "workshop/switch_project", to: "products#switch_project", as: :switch_workshop_project

  resource :profile, only: [ :show, :update ]
  resources :workspace_members, only: [ :index, :new, :create, :edit, :update, :destroy ] do
    member do
      post :become
    end
  end
  post :stop_impersonating, to: "workspace_members#stop_impersonating"

  resources :clients
  resource :workspace_settings, only: [ :show, :update ] do
    post :test_github, on: :collection
  end
  resources :discord_reminder_recipients, only: [ :create, :update, :destroy ]
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
    resource :project_report, only: [ :show ]
  end

  # API endpoints for dynamic UI
  get "projects/:project_id/tasks_list", to: "tasks#list", as: :project_tasks_list

  # Workshop: Idea → Brief pipeline (and Brief → Task relocation)
  get  "workshop",                 to: "workshop#index",    as: :workshop
  get  "workshop/new_idea",        to: "workshop#new_idea", as: :new_idea_workshop
  post "workshop/start",           to: "workshop#start",    as: :start_workshop
  get  "workshop/tasks/:id/brief", to: "workshop#brief",    as: :workshop_brief

  # Workshop redesign (Clar): Create Tasks pipeline + idea intake. Additive —
  # more routes (advance/save_locally/push_jira, versions, design_request,
  # process/reporting/bugs/configuration) land in later phases.
  namespace :workshop do
    get "pipeline", to: "pipeline#index", as: :pipeline
    get "jira_browser", to: "jira_browser#show", as: :jira_browser
    resources :ideas, only: [ :create, :show, :update ] do
      member { post :advance }
    end
  end

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
    post :breakdown_update_jira, to: "task_breakdowns#update_jira"
    resources :task_breakdowns, only: [:index]
    resource :breakdown_chat_session, only: [:create, :show, :destroy] do
      post :message
    end

    # Workshop: brief conversation + versioned briefs + commit-to-Jira
    resource :brief_chat_session, only: [:create, :show, :destroy] do
      post :message
    end
    resources :briefs, only: [] do
      member { post :commit, to: "brief_commits#commit" }
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
