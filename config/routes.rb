Rails.application.routes.draw do
  # Trang chủ là trang login
  root "sessions#new"
  
  # Routes cho authentication
  get "login", to: "sessions#new"
  post "login", to: "sessions#create"
  delete "logout", to: "sessions#destroy"
  
  # Menu chính sau khi login
  get "menu", to: "menu#index"
  
  # Routes cho bulk mails
  resources :bulk_mails, only: [:index, :new, :create]
  # Hoặc có thể dùng: get 'bulk_mails', to: 'bulk_mails#new'
  
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest

  # Defines the root path route ("/")
  # root "posts#index"
end
