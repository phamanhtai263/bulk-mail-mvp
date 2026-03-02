require 'net/http'
require 'json'

class RailwayService
  GRAPHQL_ENDPOINT = "https://backboard.railway.com/graphql/v2".freeze

  def initialize
    @token       = ENV.fetch("RAILWAY_API_TOKEN", "")
    @service_id  = ENV.fetch("RAILWAY_SERVICE_ID", "")
    @environment_id = ENV.fetch("RAILWAY_ENVIRONMENT_ID", "")
  end

  # Lấy trạng thái service hiện tại
  # Trả về: { status: "ACTIVE"|"REMOVED"|"SLEEPING"|nil, error: nil|"..." }
  def status
    query = <<~GQL
      query {
        service(id: "#{@service_id}") {
          serviceInstances {
            edges {
              node {
                status
                sleepStatus
              }
            }
          }
        }
      }
    GQL

    result = call_api(query)
    return { status: nil, error: result[:error] } if result[:error]

    instance = result.dig(:data, "service", "serviceInstances", "edges", 0, "node")
    return { status: nil, error: "Không tìm thấy service instance" } unless instance

    sleep_status = instance["sleepStatus"]
    status_val   = instance["status"]

    display = if sleep_status == "SLEEPING" || sleep_status == "sleeping"
      "SLEEPING"
    else
      status_val || "UNKNOWN"
    end

    { status: display, error: nil }
  rescue => e
    { status: nil, error: e.message }
  end

  # Suspend service (tắt, ngừng tính tiền)
  def suspend
    mutation = <<~GQL
      mutation {
        serviceInstanceSuspend(
          serviceId: "#{@service_id}",
          environmentId: "#{@environment_id}"
        )
      }
    GQL

    result = call_api(mutation)
    return { success: false, error: result[:error] } if result[:error]

    { success: true, error: nil }
  rescue => e
    { success: false, error: e.message }
  end

  private

  def call_api(query)
    uri  = URI(GRAPHQL_ENDPOINT)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl     = true
    http.read_timeout = 15
    http.open_timeout = 10

    req = Net::HTTP::Post.new(uri.path)
    req["Authorization"]  = "Bearer #{@token}"
    req["Content-Type"]   = "application/json"
    req.body = { query: query }.to_json

    res = http.request(req)

    unless res.is_a?(Net::HTTPSuccess)
      return { error: "Railway API HTTP #{res.code}: #{res.body[0..100]}" }
    end

    parsed = JSON.parse(res.body)

    if parsed["errors"].present?
      msgs = parsed["errors"].map { |e| e["message"] }.join(", ")
      return { error: "Railway API error: #{msgs}" }
    end

    { data: parsed["data"], error: nil }
  rescue => e
    { error: "Lỗi kết nối Railway API: #{e.message}" }
  end
end
