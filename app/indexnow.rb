#!/usr/bin/env ruby
# encoding: utf-8
require 'json'
require 'net/http'
require 'uri'

module IndexNow
  KEY = 'd068c8f1c644480d66a165b92cb1b4eb'
  SITE = 'https://monitorg.by'
  API = 'https://yandex.com/indexnow'
  BATCH = 10_000

  def self.urls(lines)
    paths = lines.map(&:strip).select { |s| s.start_with?('/') }
    return paths.map { |p| "#{SITE}#{p}" }.uniq if paths.any?

    lines.map { |s| s.strip.sub(/\Adeleting\s+/, '') }
         .map { |p| p =~ %r{\A_p/(.+)\.html\z} ? "#{$1}/index.html" : p }
         .select { |p| p == 'index.html' || p.end_with?('/index.html') }
         .reject { |p| p =~ %r{\A(_test|admin|st)/} }
         .map { |p| "#{SITE}/#{p.sub(/index\.html\z/, '')}" }
         .map { |u| u =~ %r{/(about|help|privacy|cookies|news|news/[^/]+|calc/(torgi|bav))/\z} ? u.chomp('/') : u }.uniq
  end

  def self.send_all(urls)
    urls.each_slice(BATCH) do |sl|
      req = Net::HTTP::Post.new(URI(API), 'Content-Type' => 'application/json; charset=utf-8')
      req.body = JSON.generate(host: 'monitorg.by', key: KEY, keyLocation: "#{SITE}/#{KEY}.txt", urlList: sl)
      res = Net::HTTP.start('yandex.com', 443, use_ssl: true, open_timeout: 20, read_timeout: 60) { |h| h.request(req) }
      puts "IndexNow: #{sl.size} адресов → #{res.code}"
    end
  rescue StandardError => e
    puts "::warning::IndexNow не отправлен: #{e.message}"
  end
end

if $PROGRAM_NAME == __FILE__
  exit 0 unless ENV['SEO_LIVE'] == '1'
  f = ARGV[0].to_s
  exit 0 unless File.exist?(f)
  u = IndexNow.urls(File.readlines(f, encoding: 'UTF-8'))
  u.empty? ? puts('IndexNow: изменённых страниц нет') : IndexNow.send_all(u)
end
