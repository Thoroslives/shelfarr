# frozen_string_literal: true

require "nokogiri"
require "faraday/follow_redirects"

# Client for interacting with Anna's Archive
# Search via HTML scraping, downloads via member API
class AnnaArchiveClient
  # Custom error classes
  class Error < StandardError; end
  class ConnectionError < Error; end
  class AuthenticationError < Error; end
  class NotConfiguredError < Error; end
  class ScrapingError < Error; end
  class BotProtectionError < Error; end
  class FreeDownloadError < Error; end

  # Data structure for search results
  Result = Data.define(
    :md5, :title, :author, :year,
    :file_type, :file_size, :language
  ) do
    def downloadable?
      md5.present?
    end

    def size_human
      file_size
    end
  end

  # Circuit breaker state per mirror (class-level, in-memory)
  CIRCUIT_FAILURE_THRESHOLD = 3
  CIRCUIT_COOLDOWN_SECONDS = 300 # 5 minutes
  ZLIB_AUTH_TTL_SECONDS = 1800 # 30 minutes

  @circuit_breakers = {}
  @zlib_auth_cache = nil

  class << self
    # Check if Anna's Archive is enabled for search (no API key needed)
    def configured?
      SettingsService.get(:anna_archive_enabled, default: false)
    end

    # Check if paid API key is available for fast downloads
    def has_api_key?
      SettingsService.configured?(:anna_archive_api_key)
    end

    def reset_circuit_breakers!
      @circuit_breakers = {}
      @zlib_auth_cache = nil
    end

    # Search for books via HTML scraping
    # Returns array of Result
    # @param language [String] ISO 639-1 language code (e.g., "en", "fr", "de")
    def search(query, file_types: %w[epub pdf], limit: 50, language: nil)
      ensure_configured!

      url = build_search_url(query, file_types, language: language)
      full_url = "#{base_url}#{url}"
      Rails.logger.info "[AnnaArchiveClient] Searching: #{url}"

      html = fetch_with_protection_bypass(full_url)
      parse_search_results(html, limit)
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      raise ConnectionError, "Failed to connect to Anna's Archive: #{e.message}"
    end

    # Get download URL (torrent) via fast_download API
    # Requires member API key
    def get_download_url(md5, path_index: 0, domain_index: 0)
      ensure_configured!

      params = {
        md5: md5,
        key: api_key,
        path_index: path_index,
        domain_index: domain_index
      }

      response = connection.get("/dyn/api/fast_download.json", params)
      data = JSON.parse(response.body)

      if data["error"]
        raise Error, "Anna's Archive API error: #{data['error']}"
      end

      download_url = data["download_url"]
      raise Error, "No download URL returned" if download_url.blank?

      download_url
    rescue JSON::ParserError => e
      raise Error, "Failed to parse Anna's Archive response: #{e.message}"
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      raise ConnectionError, "Failed to connect to Anna's Archive API: #{e.message}"
    end

    # Get download URL via free mirror scraping
    # Parses the MD5 detail page for mirror links and tries each in priority order
    def get_free_download_url(md5)
      ensure_configured!

      Rails.logger.info "[AnnaArchiveClient] Fetching free download URL for MD5: #{md5}"

      md5_url = "#{base_url}/md5/#{md5}"
      md5_html = fetch_with_protection_bypass(md5_url)

      mirrors = extract_mirror_links(md5_html)
      if mirrors.empty?
        raise FreeDownloadError, "No mirror links found on MD5 page for: #{md5}"
      end

      Rails.logger.info "[AnnaArchiveClient] Found #{mirrors.size} mirror(s): #{mirrors.map { |m| m[:name] }.join(', ')}"

      last_error = nil
      mirrors.each do |mirror|
        if circuit_open?(mirror[:name])
          Rails.logger.info "[AnnaArchiveClient] Skipping #{mirror[:name]} (circuit breaker open)"
          next
        end

        begin
          url = resolve_mirror_download(mirror)
          if url.present?
            record_mirror_success(mirror[:name])
            Rails.logger.info "[AnnaArchiveClient] Got free download URL via #{mirror[:name]}: #{url.truncate(100)}"
            return url
          end
        rescue => e
          record_mirror_failure(mirror[:name])
          Rails.logger.warn "[AnnaArchiveClient] Mirror #{mirror[:name]} failed: #{e.message}"
          last_error = e
        end
      end

      raise FreeDownloadError, "All #{mirrors.size} mirror(s) failed for MD5: #{md5}. Last error: #{last_error&.message}"
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      raise ConnectionError, "Failed to connect: #{e.message}"
    end

    # Test connection by fetching search page
    def test_connection
      response = connection.get("/")
      response.status == 200
    rescue Error, Faraday::Error
      false
    end

    private

    def fetch_with_protection_bypass(url)
      if FlaresolverrClient.configured?
        Rails.logger.info "[AnnaArchiveClient] Using FlareSolverr for request"
        FlaresolverrClient.get(url)
      else
        response = connection.get(url)

        # Detect bot protection
        if response.status == 403 || bot_protection_detected?(response.body)
          raise BotProtectionError, "Anna's Archive requires FlareSolverr to bypass DDoS protection. " \
                                    "Please configure FlareSolverr URL in settings."
        end

        raise Error, "Search failed with status #{response.status}" unless response.status == 200
        response.body
      end
    rescue FlaresolverrClient::Error => e
      raise ConnectionError, "FlareSolverr error: #{e.message}"
    end

    def bot_protection_detected?(html)
      return false if html.blank?

      html.include?("DDoS-Guard") ||
        html.include?("ddos-guard") ||
        html.include?("Checking your browser") ||
        html.include?("Just a moment") ||
        html.include?("Enable JavaScript and cookies")
    end

    def ensure_configured!
      unless configured?
        raise NotConfiguredError, "Anna's Archive is not configured or enabled"
      end
    end

    def circuit_open?(mirror_name)
      state = @circuit_breakers[mirror_name]
      return false unless state
      return false if state[:failures] < CIRCUIT_FAILURE_THRESHOLD

      # Check if cooldown has expired
      if state[:open_until] && Time.current > state[:open_until]
        @circuit_breakers.delete(mirror_name)
        return false
      end

      true
    end

    def record_mirror_failure(mirror_name)
      @circuit_breakers[mirror_name] ||= { failures: 0, open_until: nil }
      state = @circuit_breakers[mirror_name]
      state[:failures] += 1

      if state[:failures] >= CIRCUIT_FAILURE_THRESHOLD
        state[:open_until] = Time.current + CIRCUIT_COOLDOWN_SECONDS
        Rails.logger.warn "[AnnaArchiveClient] Circuit breaker OPEN for #{mirror_name} (#{CIRCUIT_COOLDOWN_SECONDS}s cooldown)"
      end
    end

    def record_mirror_success(mirror_name)
      @circuit_breakers.delete(mirror_name)
    end

    def connection
      @connection ||= Faraday.new(url: base_url) do |f|
        f.request :url_encoded
        f.adapter Faraday.default_adapter
        f.headers["User-Agent"] = "Shelfarr/1.0"
        f.options.timeout = 30
        f.options.open_timeout = 10
      end
    end

    # Extract mirror links from the MD5 page download panel
    def extract_mirror_links(html)
      doc = Nokogiri::HTML(html)
      panel = doc.at_css("#md5-panel-downloads")
      return [] unless panel

      mirrors = []
      panel.css("a[href]").each do |link|
        href = link["href"].to_s
        next if href.blank?
        next if href.include?("slow_download")

        mirror = classify_mirror(href, link.text.to_s)
        mirrors << mirror if mirror
      end

      # Sort by priority: libgen first, then zlibrary, then ipfs, then unknown
      priority = { libgen: 0, zlibrary: 1, ipfs: 2, unknown: 3 }
      mirrors.sort_by { |m| priority[m[:name]] || 99 }
    end

    def classify_mirror(href, text)
      if href.include?("libgen")
        { name: :libgen, url: href }
      elsif href.include?("z-lib") || href.include?("zlibrary") || href.include?("singlelogin")
        { name: :zlibrary, url: href }
      elsif href.include?("ipfs")
        { name: :ipfs, url: href }
      elsif href.start_with?("http")
        { name: :unknown, url: href }
      end
    end

    def resolve_mirror_download(mirror)
      case mirror[:name]
      when :libgen
        resolve_libgen_download(mirror[:url])
      when :zlibrary
        resolve_zlibrary_download(mirror[:url])
      when :ipfs
        resolve_ipfs_download(mirror[:url])
      else
        Rails.logger.info "[AnnaArchiveClient] Skipping unknown mirror: #{mirror[:url]}"
        nil
      end
    end

    def resolve_libgen_download(url)
      Rails.logger.info "[AnnaArchiveClient] Resolving LibGen download: #{url}"

      response = mirror_connection.get(url)
      raise FreeDownloadError, "LibGen ads page returned #{response.status}" unless response.status == 200

      require "nokogiri"
      doc = Nokogiri::HTML(response.body)
      get_link = doc.at_css("a[href*='get.php']")
      unless get_link
        raise FreeDownloadError, "No get.php download link found on LibGen ads page"
      end

      download_path = get_link["href"].to_s
      return nil if download_path.blank?

      # Build absolute URL if relative
      if download_path.start_with?("http")
        download_path
      else
        uri = URI.parse(url)
        "#{uri.scheme}://#{uri.host}/#{download_path.delete_prefix('/')}"
      end
    end

    def resolve_zlibrary_download(url)
      unless zlibrary_configured?
        Rails.logger.info "[AnnaArchiveClient] Z-Library not configured, skipping: #{url}"
        return nil
      end

      Rails.logger.info "[AnnaArchiveClient] Resolving Z-Library download: #{url}"

      # Step 1: Login to get remix tokens and discover domains
      zlib_auth = zlibrary_login
      return nil unless zlib_auth

      # Step 2: Follow the AA link to find the book page (extract book ID and hash)
      book_info = zlibrary_extract_book_info(url, zlib_auth)
      return nil unless book_info

      # Step 3: Get download link via eAPI
      zlibrary_get_download_link(book_info, zlib_auth)
    rescue => e
      Rails.logger.warn "[AnnaArchiveClient] Z-Library resolver failed: #{e.message}"
      nil
    end

    def resolve_ipfs_download(url)
      # IPFS gateway URLs are typically direct downloads
      Rails.logger.info "[AnnaArchiveClient] Resolving IPFS download: #{url}"

      response = mirror_connection.head(url)
      if response.status.between?(200, 399)
        url
      else
        raise FreeDownloadError, "IPFS gateway returned #{response.status}"
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise FreeDownloadError, "IPFS gateway unreachable: #{e.message}"
    end

    def zlibrary_configured?
      SettingsService.get(:zlibrary_email).present? &&
        SettingsService.get(:zlibrary_password).present?
    end

    def zlibrary_login
      # Return cached auth if still valid
      if @zlib_auth_cache && @zlib_auth_cache[:expires_at] > Time.current
        return @zlib_auth_cache[:auth]
      end

      email = SettingsService.get(:zlibrary_email)
      password = SettingsService.get(:zlibrary_password)

      # Try known Z-Library domains for eAPI login
      domains = %w[z-library.bz 1lib.sk z-lib.fm z-lib.sk]

      domains.each do |domain|
        begin
          response = mirror_connection.post("https://#{domain}/eapi/user/login") do |req|
            req.headers["Content-Type"] = "application/x-www-form-urlencoded"
            req.body = URI.encode_www_form(email: email, password: password)
          end

          next unless response.status == 200

          data = JSON.parse(response.body)
          if data["success"] == 1
            Rails.logger.info "[AnnaArchiveClient] Z-Library login successful via #{domain}"
            auth = {
              remix_userid: data.dig("user", "remix_userid")&.to_s,
              remix_userkey: data.dig("user", "remix_userkey")&.to_s,
              domain: domain
            }
            @zlib_auth_cache = { auth: auth, expires_at: Time.current + ZLIB_AUTH_TTL_SECONDS }
            return auth
          end
        rescue JSON::ParserError, Faraday::Error => e
          Rails.logger.debug "[AnnaArchiveClient] Z-Library login failed on #{domain}: #{e.message}"
          next
        end
      end

      Rails.logger.warn "[AnnaArchiveClient] Z-Library login failed on all domains"
      nil
    end

    def zlibrary_extract_book_info(aa_url, auth)
      # The URL from AA's MD5 page looks like https://z-lib.gd/md5/abc123
      # Following it (when logged in) redirects to /book/{id}/{hash}
      # We need to extract the book ID and hash

      response = mirror_connection.get(aa_url) do |req|
        req.headers["Cookie"] = "remix_userid=#{auth[:remix_userid]}; remix_userkey=#{auth[:remix_userkey]}"
      end

      # Check if we got redirected to a book page
      final_url = response.env.url.to_s
      book_match = final_url.match(%r{/book/(\d+)/([a-f0-9]+)}i)

      unless book_match
        # Try parsing the response body for book links
        require "nokogiri"
        doc = Nokogiri::HTML(response.body)
        book_link = doc.at_css("a[href*='/book/']")
        if book_link
          book_match = book_link["href"].match(%r{/book/(\d+)/([a-f0-9]+)}i)
        end
      end

      unless book_match
        Rails.logger.warn "[AnnaArchiveClient] Could not extract Z-Library book ID from: #{aa_url}"
        return nil
      end

      { id: book_match[1], hash: book_match[2] }
    end

    def zlibrary_get_download_link(book_info, auth)
      domain = auth[:domain]
      book_id = book_info[:id]
      book_hash = book_info[:hash]

      url = "https://#{domain}/eapi/book/#{book_id}/#{book_hash}/file"
      response = mirror_connection.get(url) do |req|
        req.headers["Cookie"] = "remix_userid=#{auth[:remix_userid]}; remix_userkey=#{auth[:remix_userkey]}"
      end

      return nil unless response.status == 200

      data = JSON.parse(response.body)
      download_link = data["downloadLink"]

      if download_link.present?
        Rails.logger.info "[AnnaArchiveClient] Got Z-Library download link: #{download_link.truncate(100)}"
        download_link
      else
        Rails.logger.warn "[AnnaArchiveClient] Z-Library returned no download link for book #{book_id}"
        nil
      end
    rescue JSON::ParserError => e
      Rails.logger.warn "[AnnaArchiveClient] Z-Library download response parse error: #{e.message}"
      nil
    end

    def mirror_connection
      @mirror_connection ||= Faraday.new do |f|
        f.request :url_encoded
        f.response :follow_redirects
        f.adapter Faraday.default_adapter
        f.headers["User-Agent"] = "Mozilla/5.0 (compatible; Shelfarr/1.0)"
        f.options.timeout = 30
        f.options.open_timeout = 10
      end
    end

    def base_url
      SettingsService.get(:anna_archive_url, default: "https://annas-archive.org")
    end

    def api_key
      SettingsService.get(:anna_archive_api_key)
    end

    def build_search_url(query, file_types, language: nil)
      encoded_query = URI.encode_www_form_component(query)
      ext_param = Array(file_types).join(",")

      # Anna's Archive search URL pattern
      # Sort by "most_relevant" for best matches
      url = "/search?q=#{encoded_query}&ext=#{ext_param}&sort=&content=book_nonfiction,book_fiction,book_unknown"

      # Add language filter if specified
      # Anna's Archive uses ISO 639-1 codes (e.g., en, fr, de)
      url += "&lang=#{language}" if language.present?

      url
    end

    def parse_search_results(html, limit)
      doc = Nokogiri::HTML(html)
      results = []

      # Anna's Archive uses a specific structure for search results
      # Each result is typically in a div/article with a link to /md5/{hash}
      doc.css("a[href*='/md5/']").each do |link|
        break if results.size >= limit

        result = parse_result_element(link)
        results << result if result
      end

      Rails.logger.info "[AnnaArchiveClient] Parsed #{results.size} results"
      results
    rescue => e
      Rails.logger.error "[AnnaArchiveClient] Scraping error: #{e.message}"
      raise ScrapingError, "Failed to parse search results: #{e.message}"
    end

    def parse_result_element(link)
      href = link["href"]
      return nil unless href

      # Extract MD5 from URL like /md5/abc123def456...
      md5_match = href.match(/\/md5\/([a-f0-9]+)/i)
      return nil unless md5_match

      md5 = md5_match[1]

      # Get the parent container that holds all result info
      container = find_result_container(link)
      return nil unless container

      # Extract text content
      text = container.text.to_s

      # Try to parse title, author, and metadata from the text
      title = extract_title(container, link)
      author = extract_author(container, text)
      file_type = extract_file_type(container, text)
      file_size = extract_file_size(text)
      language = extract_language(text)
      year = extract_year(text)

      return nil if title.blank?

      Result.new(
        md5: md5,
        title: title,
        author: author,
        year: year,
        file_type: file_type,
        file_size: file_size,
        language: language
      )
    end

    def find_result_container(link)
      # Walk up the DOM to find the containing element
      # Anna's Archive typically wraps each result in a container
      parent = link
      5.times do
        break if parent.nil? || parent.is_a?(Nokogiri::HTML4::Document)
        parent = parent.parent
        break if parent.nil? || parent.is_a?(Nokogiri::HTML4::Document)
        # Look for a container that seems like a search result item
        if parent.name == "div" || parent.name == "article"
          # Check if it has enough content to be a result
          return parent if parent.text.to_s.length > 50
        end
      end
      # Fallback to link's parent if valid
      link.parent unless link.parent.is_a?(Nokogiri::HTML4::Document)
    end

    def extract_title(container, link)
      # The title is usually in the link element itself if it has certain classes
      # Look for the main title link with font-semibold text-lg
      title_link = container.at_css('a[class*="font-semibold"][class*="text-lg"]')
      return title_link.text.strip if title_link && title_link.text.present?

      # Or check if the link we found is the title link
      if link["class"]&.include?("font-semibold")
        return link.text.strip if link.text.present?
      end

      # Try to find a heading or prominent text
      heading = container.at_css("h3, h4, .title, [class*='title']")
      return heading.text.strip if heading && heading.text.present?

      # Look for data-content attribute which holds fallback title
      fallback = container.at_css('[data-content]')
      if fallback && fallback["data-content"].present?
        return fallback["data-content"]
      end

      nil
    end

    def extract_author(container, text)
      # Look for author link with user-edit icon
      author_link = container.at_css('a[href^="/search?q="] span[class*="user-edit"]')
      if author_link
        parent = author_link.parent
        return parent.text.strip if parent && parent.text.present?
      end

      # Look for author-specific elements
      author_el = container.at_css(".author, [class*='author']")
      return author_el.text.strip if author_el && author_el.text.present?

      # Look for data-content with author info
      author_fallback = container.css('[data-content]')[1]  # Second data-content is usually author
      if author_fallback && author_fallback["data-content"].present?
        return author_fallback["data-content"]
      end

      # Try common patterns: "by Author Name"
      if text =~ /\bby\s+([A-Z][^,\n\d]{3,50})/i
        return $1.strip
      end

      nil
    end

    def extract_file_type(container, text)
      # Look for file extension badges
      badge = container.at_css("[class*='badge'], [class*='ext'], [class*='format']")
      if badge
        ext = badge.text.strip.downcase
        return ext if %w[epub pdf mobi azw3 djvu mp3 m4b].include?(ext)
      end

      # Match from text
      if text =~ /\b(epub|pdf|mobi|azw3|djvu|mp3|m4b)\b/i
        return $1.downcase
      end

      nil
    end

    def extract_file_size(text)
      # Match patterns like "15.2 MB", "1.5 GB"
      if text =~ /(\d+(?:\.\d+)?)\s*(KB|MB|GB)/i
        "#{$1} #{$2.upcase}"
      end
    end

    def extract_language(text)
      # Common language patterns
      languages = {
        "english" => "en", "en" => "en",
        "spanish" => "es", "español" => "es", "es" => "es",
        "french" => "fr", "français" => "fr", "fr" => "fr",
        "german" => "de", "deutsch" => "de", "de" => "de",
        "portuguese" => "pt", "português" => "pt", "pt" => "pt",
        "italian" => "it", "italiano" => "it", "it" => "it",
        "russian" => "ru", "ru" => "ru",
        "chinese" => "zh", "zh" => "zh",
        "japanese" => "ja", "ja" => "ja"
      }

      text_lower = text.downcase
      languages.each do |pattern, code|
        return code if text_lower.include?(pattern)
      end

      nil
    end

    def extract_year(text)
      # Match 4-digit years between 1800 and 2030
      if text =~ /\b(1[89]\d{2}|20[0-2]\d)\b/
        $1.to_i
      end
    end
  end
end
