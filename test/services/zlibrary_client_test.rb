# frozen_string_literal: true

require "test_helper"

class ZLibraryClientTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:zlibrary_email, "test@example.com")
    SettingsService.set(:zlibrary_password, "testpass")
    ZLibraryClient.reset_auth_cache!
  end

  teardown do
    SettingsService.set(:zlibrary_email, "")
    SettingsService.set(:zlibrary_password, "")
    ZLibraryClient.reset_auth_cache!
  end

  test "configured? returns true when both email and password set" do
    assert ZLibraryClient.configured?
  end

  test "configured? returns false when email missing" do
    SettingsService.set(:zlibrary_email, "")
    assert_not ZLibraryClient.configured?
  end

  test "configured? returns false when password missing" do
    SettingsService.set(:zlibrary_password, "")
    assert_not ZLibraryClient.configured?
  end

  test "login succeeds and caches auth" do
    VCR.turned_off do
      stub_zlibrary_login_success

      auth = ZLibraryClient.send(:login)

      assert_equal "12345", auth[:remix_userid]
      assert_equal "abcdef123456", auth[:remix_userkey]
      assert_equal "z-library.bz", auth[:domain]
    end
  end

  test "login tries next domain on failure" do
    VCR.turned_off do
      stub_request(:post, "https://z-library.bz/eapi/user/login")
        .to_return(status: 500, body: "Server Error")
      stub_request(:post, "https://1lib.sk/eapi/user/login")
        .to_return(
          status: 200,
          body: { success: 1, user: { id: "12345", remix_userkey: "abcdef123456" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      auth = ZLibraryClient.send(:login)

      assert_equal "1lib.sk", auth[:domain]
    end
  end

  test "login returns nil when all domains fail" do
    VCR.turned_off do
      stub_zlibrary_login_all_fail

      auth = ZLibraryClient.send(:login)

      assert_nil auth
    end
  end

  test "login caches auth for subsequent calls" do
    VCR.turned_off do
      stub_zlibrary_login_success

      auth1 = ZLibraryClient.send(:login)
      auth2 = ZLibraryClient.send(:login)

      assert_equal auth1, auth2
      assert_requested(:post, "https://z-library.bz/eapi/user/login", times: 1)
    end
  end

  private

  def stub_zlibrary_login_success
    stub_request(:post, "https://z-library.bz/eapi/user/login")
      .to_return(
        status: 200,
        body: {
          success: 1,
          user: { id: "12345", remix_userkey: "abcdef123456" }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def stub_zlibrary_login_all_fail
    %w[z-library.bz 1lib.sk z-lib.fm z-lib.sk].each do |domain|
      stub_request(:post, "https://#{domain}/eapi/user/login")
        .to_return(status: 500, body: "Server Error")
    end
  end
end
