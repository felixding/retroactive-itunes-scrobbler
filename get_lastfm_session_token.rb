#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'digest/md5'
require 'net/http'
require 'uri'
require 'yaml'

CONFIG_FILE = File.join(__dir__, 'config.yml')
abort('config.yml not found; copy config.yml.example first.') unless File.exist?(CONFIG_FILE)

config = YAML.load_file(CONFIG_FILE)
API_KEY = config.dig('lastfm', 'api_key')
API_SECRET = config.dig('lastfm', 'api_secret')
abort('Set lastfm.api_key and lastfm.api_secret in config.yml first.') if API_KEY.to_s.empty? || API_SECRET.to_s.empty?

# Helper to GET JSON

def get_json(url)
  uri = URI(url)
  res = Net::HTTP.get_response(uri)
  raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
  JSON.parse(res.body)
end

# Step 1: Get request token

token_url = "https://ws.audioscrobbler.com/2.0/?method=auth.gettoken&api_key=#{API_KEY}&format=json"
token_json = get_json(token_url)
token = token_json['token'] or abort('No token returned')

puts "Request token: #{token}\n"
puts 'Open this URL in your browser and click Allow:'
puts "https://www.last.fm/api/auth/?api_key=#{API_KEY}&token=#{token}"
puts
print 'Press ENTER after you authorize...'
STDIN.gets

# Step 2: Build API signature for auth.getSession

sig_base = "api_key#{API_KEY}methodauth.getSessiontoken#{token}#{API_SECRET}"
api_sig = Digest::MD5.hexdigest(sig_base)

# Step 3: Exchange for session key

session_url = 'https://ws.audioscrobbler.com/2.0/'
params = {
  method: 'auth.getSession',
  api_key: API_KEY,
  api_sig: api_sig,
  token: token,
  format: 'json'
}

uri = URI(session_url)
res = Net::HTTP.post_form(uri, params)
json = JSON.parse(res.body)

puts "\nResponse:" 
puts JSON.pretty_generate(json)

if json['session'] && json['session']['key']
  sk = json['session']['key']
  puts "\nYour Session Key (sk): #{sk}"
  puts "Add it to config.yml under lastfm.session_key"
else
  abort('Failed to get session key.')
end
