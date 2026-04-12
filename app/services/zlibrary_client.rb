# frozen_string_literal: true

# Client for searching and downloading ebooks via Z-Library's eAPI
# Requires Z-Library account credentials (email + password)
class ZLibraryClient
  class Error < StandardError; end
  class ConnectionError < Error; end
  class AuthenticationError < Error; end
  class NotConfiguredError < Error; end

  Result = Data.define(
    :id, :hash, :title, :author, :year,
    :file_type, :file_size, :language
  ) do
    def downloadable?
      id.present? && hash.present?
    end

    def size_human
      file_size
    end
  end

  AUTH_TTL_SECONDS = 1800 # 30 minutes
  DOMAINS = %w[z-library.bz 1lib.sk z-lib.fm z-lib.sk].freeze

  @auth_cache = nil

  class << self
    def configured?
      SettingsService.get(:zlibrary_email).present? &&
        SettingsService.get(:zlibrary_password).present?
    end

    def reset_auth_cache!
      @auth_cache = nil
    end

    # Search Z-Library for books via eAPI
    # @param query [String] Search query
    # @param file_types [Array<String>] File extensions to filter (e.g., ["epub", "pdf"])
    # @param limit [Integer] Max results
    # @param language [String] Language filter (e.g., "english")
    def search(query, file_types: %w[epub pdf], limit: 50, language: nil)
      ensure_configured!

      auth = login
      raise AuthenticationError, "Z-Library login failed" unless auth

      Rails.logger.info "[ZLibraryClient] Searching: #{query}"

      body_parts = [["message", query], ["limit", limit.to_s]]
      file_types.each { |ext| body_parts << ["extensions[]", ext] }
      body_parts << ["languages[]", language] if language.present?

      response = connection.post("https://#{auth[:domain]}/eapi/book/search") do |req|
        req.headers["Content-Type"] = "application/x-www-form-urlencoded"
        req.headers["Cookie"] = "remix_userid=#{auth[:remix_userid]}; remix_userkey=#{auth[:remix_userkey]}"
        req.body = URI.encode_www_form(body_parts)
      end

      raise ConnectionError, "Search failed with status #{response.status}" unless response.status == 200

      data = JSON.parse(response.body)
      books = data["books"] || []

      results = parse_search_results(books, limit)
      Rails.logger.info "[ZLibraryClient] Found #{results.size} results"
      results
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      raise ConnectionError, "Failed to connect to Z-Library: #{e.message}"
    end

    private

    def login
      # Return cached auth if still valid
      if @auth_cache && @auth_cache[:expires_at] > Time.current
        return @auth_cache[:auth]
      end

      email = SettingsService.get(:zlibrary_email)
      password = SettingsService.get(:zlibrary_password)

      DOMAINS.each do |domain|
        begin
          response = connection.post("https://#{domain}/eapi/user/login") do |req|
            req.headers["Content-Type"] = "application/x-www-form-urlencoded"
            req.body = URI.encode_www_form(email: email, password: password)
          end

          next unless response.status == 200

          data = JSON.parse(response.body)
          if data["success"] == 1
            Rails.logger.info "[ZLibraryClient] Login successful via #{domain}"
            auth = {
              remix_userid: data.dig("user", "id")&.to_s,
              remix_userkey: data.dig("user", "remix_userkey")&.to_s,
              domain: domain
            }
            @auth_cache = { auth: auth, expires_at: Time.current + AUTH_TTL_SECONDS }
            return auth
          end
        rescue JSON::ParserError, Faraday::Error => e
          Rails.logger.debug "[ZLibraryClient] Login failed on #{domain}: #{e.message}"
          next
        end
      end

      Rails.logger.warn "[ZLibraryClient] Login failed on all domains"
      nil
    end

    def ensure_configured!
      raise NotConfiguredError, "Z-Library is not configured" unless configured?
    end

    def parse_search_results(books, limit)
      books.first(limit).filter_map do |book|
        id = book["id"]&.to_s
        hash = book["hash"]&.to_s
        next if id.blank? || hash.blank?

        Result.new(
          id: id,
          hash: hash,
          title: book["name"].presence || book["title"].presence || "Unknown",
          author: book["author"].presence || "Unknown",
          year: book["year"].to_i.nonzero?,
          file_type: book["extension"]&.downcase,
          file_size: format_file_size(book["filesize"]),
          language: book["language"]
        )
      end
    end

    def format_file_size(bytes_string)
      bytes = bytes_string.to_i
      return nil if bytes <= 0

      if bytes >= 1_073_741_824
        "#{(bytes / 1_073_741_824.0).round(1)} GB"
      elsif bytes >= 1_048_576
        "#{(bytes / 1_048_576.0).round(1)} MB"
      elsif bytes >= 1024
        "#{(bytes / 1024.0).round(1)} KB"
      else
        "#{bytes} B"
      end
    end

    def connection
      @connection ||= Faraday.new do |f|
        f.request :url_encoded
        f.adapter Faraday.default_adapter
        f.headers["User-Agent"] = "Mozilla/5.0 (compatible; Shelfarr/1.0)"
        f.options.timeout = 30
        f.options.open_timeout = 10
      end
    end
  end
end
