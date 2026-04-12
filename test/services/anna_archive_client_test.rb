# frozen_string_literal: true

require "test_helper"

class AnnaArchiveClientTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:anna_archive_enabled, true)
    SettingsService.set(:anna_archive_url, "https://annas-archive.org")
    SettingsService.set(:anna_archive_api_key, "test-api-key")
  end

  teardown do
    SettingsService.set(:anna_archive_enabled, false)
    SettingsService.set(:anna_archive_api_key, "")
  end

  test "configured? returns true when enabled and key is set" do
    assert AnnaArchiveClient.configured?
  end

  test "configured? returns false when not enabled" do
    SettingsService.set(:anna_archive_enabled, false)
    assert_not AnnaArchiveClient.configured?
  end

  test "configured? returns true even when key is empty" do
    SettingsService.set(:anna_archive_api_key, "")
    assert AnnaArchiveClient.configured?
  end

  test "configured? returns true when enabled without API key" do
    SettingsService.set(:anna_archive_api_key, "")
    assert AnnaArchiveClient.configured?
  end

  test "has_api_key? returns true when key is set" do
    assert AnnaArchiveClient.has_api_key?
  end

  test "has_api_key? returns false when key is empty" do
    SettingsService.set(:anna_archive_api_key, "")
    assert_not AnnaArchiveClient.has_api_key?
  end

  test "search raises NotConfiguredError when not configured" do
    SettingsService.set(:anna_archive_enabled, false)

    assert_raises AnnaArchiveClient::NotConfiguredError do
      AnnaArchiveClient.search("test query")
    end
  end

  test "search parses HTML results" do
    VCR.turned_off do
      stub_anna_search_with_results

      results = AnnaArchiveClient.search("test book")

      assert results.is_a?(Array)
      assert results.any?
      assert_equal "abc123def456", results.first.md5
      assert_equal "Test Book Title", results.first.title
    end
  end

  test "search returns empty array on connection error" do
    VCR.turned_off do
      stub_request(:get, /annas-archive\.org\/search/)
        .to_raise(Faraday::ConnectionFailed.new("Connection failed"))

      assert_raises AnnaArchiveClient::ConnectionError do
        AnnaArchiveClient.search("test query")
      end
    end
  end

  test "get_download_url returns URL from API" do
    VCR.turned_off do
      stub_anna_download_api

      url = AnnaArchiveClient.get_download_url("abc123def456")

      assert_equal "magnet:?xt=urn:btih:abc123def456", url
    end
  end

  test "get_download_url raises error on API error" do
    VCR.turned_off do
      stub_request(:get, /annas-archive\.org\/dyn\/api\/fast_download\.json/)
        .to_return(
          status: 200,
          body: { error: "Invalid md5" }.to_json
        )

      assert_raises AnnaArchiveClient::Error do
        AnnaArchiveClient.get_download_url("invalid")
      end
    end
  end

  test "test_connection returns true when site is reachable" do
    VCR.turned_off do
      stub_request(:get, "https://annas-archive.org/")
        .to_return(status: 200, body: "<html></html>")

      assert AnnaArchiveClient.test_connection
    end
  end

  test "test_connection returns false when site is unreachable" do
    VCR.turned_off do
      stub_request(:get, "https://annas-archive.org/")
        .to_raise(Faraday::ConnectionFailed.new("Connection failed"))

      assert_not AnnaArchiveClient.test_connection
    end
  end

  test "search raises BotProtectionError on 403 response" do
    VCR.turned_off do
      stub_request(:get, /annas-archive\.org\/search/)
        .to_return(status: 403, body: "Forbidden")

      error = assert_raises AnnaArchiveClient::BotProtectionError do
        AnnaArchiveClient.search("test query")
      end

      assert_includes error.message, "FlareSolverr"
    end
  end

  test "search raises BotProtectionError when DDoS-Guard detected" do
    VCR.turned_off do
      stub_request(:get, /annas-archive\.org\/search/)
        .to_return(status: 200, body: "<html>DDoS-Guard protection</html>")

      error = assert_raises AnnaArchiveClient::BotProtectionError do
        AnnaArchiveClient.search("test query")
      end

      assert_includes error.message, "FlareSolverr"
    end
  end

  test "search uses FlareSolverr when configured" do
    VCR.turned_off do
      SettingsService.set(:flaresolverr_url, "http://localhost:8191")

      stub_flaresolverr_with_search_results
      results = AnnaArchiveClient.search("test book")

      assert results.is_a?(Array)
      assert results.any?
      assert_equal "abc123def456", results.first.md5

      SettingsService.set(:flaresolverr_url, "")
    end
  end

  test "get_free_download_url returns download URL via LibGen mirror" do
    VCR.turned_off do
      stub_anna_md5_page_with_mirrors
      stub_libgen_ads_page

      url = AnnaArchiveClient.get_free_download_url("abc123def456")

      assert_equal "https://libgen.li/get.php?md5=abc123def456&key=TESTKEY123", url
    end
  end

  test "get_free_download_url raises FreeDownloadError when no mirrors found" do
    VCR.turned_off do
      stub_anna_md5_page_no_mirrors

      assert_raises AnnaArchiveClient::FreeDownloadError do
        AnnaArchiveClient.get_free_download_url("abc123def456")
      end
    end
  end

  test "get_free_download_url raises FreeDownloadError when LibGen has no get.php link" do
    VCR.turned_off do
      stub_anna_md5_page_with_mirrors
      stub_libgen_ads_page_no_download

      assert_raises AnnaArchiveClient::FreeDownloadError do
        AnnaArchiveClient.get_free_download_url("abc123def456")
      end
    end
  end

  test "get_free_download_url raises NotConfiguredError when disabled" do
    SettingsService.set(:anna_archive_enabled, false)

    assert_raises AnnaArchiveClient::NotConfiguredError do
      AnnaArchiveClient.get_free_download_url("abc123def456")
    end
  end

  test "get_free_download_url skips slow_download links" do
    VCR.turned_off do
      stub_anna_md5_page_only_slow_download

      assert_raises AnnaArchiveClient::FreeDownloadError do
        AnnaArchiveClient.get_free_download_url("abc123def456")
      end
    end
  end

  test "get_free_download_url uses Z-Library when LibGen fails and Z-Library is configured" do
    VCR.turned_off do
      SettingsService.set(:zlibrary_email, "test@example.com")
      SettingsService.set(:zlibrary_password, "testpass")

      stub_anna_md5_page_with_mirrors
      # LibGen fails
      stub_request(:get, "https://libgen.li/ads.php?md5=abc123def456")
        .to_return(status: 500, body: "Server Error")
      # Z-Library login succeeds
      stub_zlibrary_login
      # Z-Library URL redirects to book page
      stub_zlibrary_book_redirect
      # Z-Library eAPI returns download link
      stub_zlibrary_download_api

      url = AnnaArchiveClient.get_free_download_url("abc123def456")

      assert_equal "https://download.z-library.bz/dl/book123/file.epub", url

      SettingsService.set(:zlibrary_email, "")
      SettingsService.set(:zlibrary_password, "")
    end
  end

  test "get_free_download_url skips Z-Library when not configured" do
    VCR.turned_off do
      stub_anna_md5_page_with_mirrors
      stub_libgen_ads_page

      # Z-Library not configured (no email/password)
      url = AnnaArchiveClient.get_free_download_url("abc123def456")

      # Should use LibGen since Z-Library is not configured
      assert_match(/libgen/, url)
    end
  end

  private

  def stub_flaresolverr_with_search_results
    html = <<~HTML
      <html>
        <body>
          <a href="/md5/abc123def456">
            <div>
              <h3>Test Book Title</h3>
              <span class="author">by Test Author</span>
              <span class="badge">epub</span>
              <span>15.2 MB</span>
              <span>English</span>
              <span>2023</span>
            </div>
          </a>
        </body>
      </html>
    HTML

    stub_request(:post, "http://localhost:8191/v1")
      .to_return(
        status: 200,
        body: {
          status: "ok",
          message: "",
          solution: {
            status: 200,
            response: html
          }
        }.to_json
      )
  end

  def stub_anna_search_with_results
    html = <<~HTML
      <html>
        <body>
          <a href="/md5/abc123def456">
            <div>
              <h3>Test Book Title</h3>
              <span class="author">by Test Author</span>
              <span class="badge">epub</span>
              <span>15.2 MB</span>
              <span>English</span>
              <span>2023</span>
            </div>
          </a>
        </body>
      </html>
    HTML

    stub_request(:get, /annas-archive\.org\/search/)
      .to_return(status: 200, body: html)
  end

  def stub_anna_download_api
    stub_request(:get, /annas-archive\.org\/dyn\/api\/fast_download\.json/)
      .with(query: hash_including({ "md5" => "abc123def456", "key" => "test-api-key" }))
      .to_return(
        status: 200,
        body: { download_url: "magnet:?xt=urn:btih:abc123def456" }.to_json
      )
  end

  def stub_anna_md5_page_with_mirrors
    html = <<~HTML
      <html>
        <body>
          <div id="md5-panel-downloads">
            <ul>
              <li><a href="/slow_download/abc123def456/0/0">Slow Server 1</a></li>
              <li><a href="https://libgen.li/ads.php?md5=abc123def456">Libgen.li</a></li>
              <li><a href="https://z-lib.gd/md5/abc123def456">Z-Library</a></li>
            </ul>
          </div>
        </body>
      </html>
    HTML

    stub_request(:get, /annas-archive\.org\/md5\/abc123def456/)
      .to_return(status: 200, body: html)
  end

  def stub_anna_md5_page_no_mirrors
    html = <<~HTML
      <html>
        <body>
          <div id="md5-panel-downloads">
            <p>No downloads available</p>
          </div>
        </body>
      </html>
    HTML

    stub_request(:get, /annas-archive\.org\/md5\/abc123def456/)
      .to_return(status: 200, body: html)
  end

  def stub_anna_md5_page_only_slow_download
    html = <<~HTML
      <html>
        <body>
          <div id="md5-panel-downloads">
            <ul>
              <li><a href="/slow_download/abc123def456/0/0">Slow Server 1</a></li>
              <li><a href="/slow_download/abc123def456/0/1">Slow Server 2</a></li>
            </ul>
          </div>
        </body>
      </html>
    HTML

    stub_request(:get, /annas-archive\.org\/md5\/abc123def456/)
      .to_return(status: 200, body: html)
  end

  def stub_libgen_ads_page
    html = <<~HTML
      <html>
        <body>
          <h1>Download</h1>
          <a href="get.php?md5=abc123def456&key=TESTKEY123">GET</a>
        </body>
      </html>
    HTML

    stub_request(:get, "https://libgen.li/ads.php?md5=abc123def456")
      .to_return(status: 200, body: html)
  end

  def stub_libgen_ads_page_no_download
    html = <<~HTML
      <html>
        <body>
          <h1>Error</h1>
          <p>File not found</p>
        </body>
      </html>
    HTML

    stub_request(:get, "https://libgen.li/ads.php?md5=abc123def456")
      .to_return(status: 200, body: html)
  end

  def stub_zlibrary_login
    stub_request(:post, "https://z-library.bz/eapi/user/login")
      .to_return(
        status: 200,
        body: {
          success: 1,
          user: {
            remix_userid: "12345",
            remix_userkey: "abcdef123456"
          }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def stub_zlibrary_book_redirect
    stub_request(:get, "https://z-lib.gd/md5/abc123def456")
      .to_return(
        status: 200,
        body: '<html><body><a href="/book/999/deadbeef">Book Page</a></body></html>'
      )
  end

  def stub_zlibrary_download_api
    stub_request(:get, "https://z-library.bz/eapi/book/999/deadbeef/file")
      .to_return(
        status: 200,
        body: {
          downloadLink: "https://download.z-library.bz/dl/book123/file.epub"
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end
end
