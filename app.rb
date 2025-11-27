#!/usr/bin/env ruby
# frozen_string_literal: true

$stdout.sync = true
$stderr.sync = true

require 'bundler/setup'
require 'net/http'
require 'uri'
require 'digest'
require 'json'
require 'yaml'
require 'logger'

puts 'Script starting...'

# Load configuration
CONFIG_FILE = File.join(__dir__, 'config.yml')
puts "Looking for config at: #{CONFIG_FILE}"
unless File.exist?(CONFIG_FILE)
  puts 'Error: config.yml not found. Please copy config.yml.example to config.yml and configure it.'
  exit 1
end

config = YAML.load_file(CONFIG_FILE)
LASTFM_API_KEY = config['lastfm']['api_key']
LASTFM_API_SECRET = config['lastfm']['api_secret']
LASTFM_SESSION_KEY = config['lastfm']['session_key']
SCROBBLE_PROGRESS_RATIO = (config.dig('scrobble', 'progress_ratio') || 0.5).to_f
puts 'Config loaded'

# Set up logging
LOG_DIR = File.expand_path('~/Library/Logs/retroactive-itunes-scrobbler')
Dir.mkdir(LOG_DIR) unless Dir.exist?(LOG_DIR)

file_logger = Logger.new(File.join(LOG_DIR, 'daemon.log'), 10, 1_024_000)
file_logger.level = Logger::INFO

stdout_logger = Logger.new($stdout)
stdout_logger.level = Logger::INFO

$logger = Logger.new($stdout)
$logger.level = Logger::INFO
$logger.extend(Module.new do
  define_method(:add) do |severity, message = nil, progname = nil, &block|
    file_logger.add(severity, message, progname, &block)
    stdout_logger.add(severity, message, progname, &block)
  end
end)

$logger.info 'Retroactive iTunes Scrobbler starting...'
$logger.info "Scrobble settings: progress_ratio=#{SCROBBLE_PROGRESS_RATIO}"
puts 'Logger initialized'

# iTunes reader using osascript (read-only)
class App
  def initialize
    $logger.info 'iTunes reader initialized (using osascript)'
  end

  def player_state
    state = `/usr/bin/osascript -e 'tell application "iTunes" to player state as string'`.strip
    state.downcase
  rescue => e
    $logger.error "Error getting player state: #{e.message}"
    'stopped'
  end

  def current_track
    return nil unless playing?

    script = <<~APPLESCRIPT
      tell application "iTunes"
        set trackName to name of current track
        set trackArtist to artist of current track
        set trackAlbum to album of current track
        set trackDuration to duration of current track
        set trackPosition to player position
        return trackName & "|" & trackArtist & "|" & trackAlbum & "|" & trackDuration & "|" & trackPosition
      end tell
    APPLESCRIPT

    result = `/usr/bin/osascript -e '#{script.gsub("'", "'\\''")}' 2>/dev/null`.strip
    return nil if result.empty?

    parts = result.split('|')
    {
      name: parts[0],
      artist: parts[1],
      album: parts[2],
      duration: parts[3].to_i,
      position: parts[4].to_i
    }
  rescue => e
    $logger.error "Error getting current track: #{e.message}"
    nil
  end

  def playing?
    player_state == 'playing'
  end
end

# Last.fm Scrobbler
class LastFmScrobbler
  SCROBBLE_API_URL = 'https://ws.audioscrobbler.com/2.0/'

  attr_reader :last_scrobbled_artist, :last_scrobbled_track, :last_scrobbled_time

  def initialize
    @last_scrobbled_artist = ''
    @last_scrobbled_track = ''
    @last_scrobbled_time = 0
    @current_track_key = nil
    @scrobbled_current = false
    $logger.info 'Last.fm scrobbler initialized'
  end

  def reset_for_track(track_key)
    @current_track_key = track_key
    @scrobbled_current = false
  end

  def check_and_scrobble(track_info)
    return unless track_info

    artist = track_info[:artist]
    track_name = track_info[:name]
    duration = track_info[:duration]
    position = track_info[:position]
    track_id = "#{artist} - #{track_name}"

    $logger.info "Track status: #{track_id} pos=#{position}s/#{duration}s"

    if @scrobbled_current && @current_track_key == track_id
      $logger.info 'Skip: already scrobbled this track in current playback'
      return
    end

    threshold = (duration * SCROBBLE_PROGRESS_RATIO).round(1)
    if position < threshold
      $logger.info "Not scrobbling yet: pos=#{position}s < threshold=#{threshold}s"
      return
    end

    if artist == @last_scrobbled_artist && track_name == @last_scrobbled_track
      time_since_last_scrobble = Time.now.to_i - @last_scrobbled_time
      if time_since_last_scrobble < (duration / 2)
        $logger.info 'Skip duplicate scrobble for current track'
        return
      end
    end

    scrobble(artist, track_name)
  rescue => e
    $logger.error "Error in check_and_scrobble: #{e.message}"
  end

  private

  def scrobble(artist, track_name)
    timestamp = Time.now.to_i

    sig_params = {
      'api_key' => LASTFM_API_KEY,
      'artist' => artist,
      'method' => 'track.scrobble',
      'sk' => LASTFM_SESSION_KEY,
      'timestamp' => timestamp.to_s,
      'track' => track_name
    }

    api_sig = generate_signature(sig_params)

    uri = URI(SCROBBLE_API_URL)
    params = sig_params.merge({
      'api_sig' => api_sig,
      'format' => 'json'
    })

    $logger.info "Scrobbling: #{track_name} by #{artist}"
    response = Net::HTTP.post_form(uri, params)
    result = JSON.parse(response.body)

    if result['scrobbles'] && result['scrobbles']['@attr'] && result['scrobbles']['@attr']['accepted'].to_i > 0
      @last_scrobbled_artist = artist
      @last_scrobbled_track = track_name
      @last_scrobbled_time = timestamp
      @scrobbled_current = true

      $logger.info "Scrobble accepted: #{track_name} by #{artist}"
      send_notification(track_name, artist)
    else
      $logger.error "Scrobble failed: #{result.inspect}"
    end
  rescue => e
    $logger.error "Scrobble error: #{e.message}"
    $logger.error e.backtrace.join("\n")
  end

  def generate_signature(params)
    sig_string = params.sort.map { |k, v| "#{k}#{v}" }.join + LASTFM_API_SECRET
    Digest::MD5.hexdigest(sig_string)
  end

  def send_notification(track_name, artist)
    notification_text = "#{track_name} - #{artist}"
    cmd = '/usr/bin/osascript'
    args = ['-e', %(display notification "#{escape_applescript(notification_text)}" with title "Scrobbled to Last.fm")]
    $logger.info "Notify: #{notification_text}"
    ok = system(cmd, *args)
    if ok
      $logger.info 'Notification sent via osascript.'
    else
      $logger.warn 'Notification command failed. Check Notification permissions for your terminal app.'
      $logger.warn "osascript exit status: #{$CHILD_STATUS.inspect}" if defined?($CHILD_STATUS)
    end
  rescue => e
    $logger.error "Notification error: #{e.message}"
  end

  def escape_applescript(str)
    str.gsub('"', '\\"').gsub("'", "\\'")
  end
end

# Main Daemon
class Daemon
  def initialize
    @itunes = App.new
    @scrobbler = LastFmScrobbler.new
    @running = false
    @monitor_thread = nil
    @last_track_logged = nil
    @was_playing = false
    $logger.info 'Daemon initialized'
  end

  def run
    $logger.info 'Starting Retroactive iTunes Scrobbler daemon...'

    setup_signal_handlers

    start_monitor_thread
    @running = true

    $logger.info 'Daemon is running. Press Ctrl+C to stop.'
    sleep while @running
  rescue Interrupt
    $logger.info 'Received interrupt signal'
    shutdown
  rescue => e
    $logger.error "Daemon error: #{e.message}"
    $logger.error e.backtrace.join("\n")
    shutdown
  end

  private

  def setup_signal_handlers
    Signal.trap('INT') { Thread.new { shutdown } }
    Signal.trap('TERM') { Thread.new { shutdown } }
  end

  def start_monitor_thread
    @monitor_thread = Thread.new do
      loop do
        begin
          if @itunes.playing?
            track_info = @itunes.current_track
            if track_info
              track_key = "#{track_info[:artist]} - #{track_info[:name]}"
              if track_key != @last_track_logged
                $logger.info "Now playing: #{track_key} (#{track_info[:position]}/#{track_info[:duration]}s)"
                @last_track_logged = track_key
                @scrobbler.reset_for_track(track_key)
              end
              @scrobbler.check_and_scrobble(track_info)
            end
            @was_playing = true
          else
            if @was_playing
              $logger.info 'Playback stopped or paused'
              @was_playing = false
              @last_track_logged = nil
            end
          end
        rescue => e
          $logger.error "Monitor thread error: #{e.message}"
        end

        sleep 10
      end
    end
  end

  def shutdown
    return unless @running

    $logger.info 'Shutting down daemon...'
    @running = false

    @monitor_thread.kill if @monitor_thread
    $logger.info 'Daemon stopped'
    exit 0
  end
end

if __FILE__ == $PROGRAM_NAME
  Daemon.new.run
end
