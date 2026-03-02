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

  # Routes cho TikTok Info
  get  "tiktok_info",       to: "tiktok_info#index", as: :tiktok_info
  post "tiktok_info/fetch", to: "tiktok_info#fetch",  as: :fetch_tiktok_info

  # Routes cho Bulk TikTok Info
  get  "bulk_tiktok_info",        to: "bulk_tiktok_info#index",  as: :bulk_tiktok_info
  post "bulk_tiktok_info/submit", to: "bulk_tiktok_info#submit", as: :bulk_tiktok_info_submit
  get  "bulk_tiktok_info/status", to: "bulk_tiktok_info#status", as: :bulk_tiktok_info_status
  get  "bulk_tiktok_info/result", to: "bulk_tiktok_info#result", as: :bulk_tiktok_info_result

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
end
