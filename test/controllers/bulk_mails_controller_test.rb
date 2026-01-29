require "test_helper"

class BulkMailsControllerTest < ActionDispatch::IntegrationTest
  test "should get create" do
    get bulk_mails_create_url
    assert_response :success
  end
end
