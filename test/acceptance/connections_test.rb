require "test_helper"
require "acceptance_test"

class ConnectionsTest < Minitest::Test
  include AcceptanceTest

  should "be able to hit Xero to get current connections via OAuth2" do
    connections = AcceptanceTestHelpers.oauth2_client.current_connections
    refute_nil connections.first.tenant_id
  end
end
