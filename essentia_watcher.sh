#!/bin/bash
# =============================================================================
# Essentia File Watcher for MusicBrainz Picard Integration
# =============================================================================
# Watches a directory for new/moved audio files and triggers essentia tagging.
# Designed to work with MusicBrainz Picard running in Docker on OMV7.
#
# Usage:
#   ./essentia_watcher.sh [options]
#
# Environment variables (or edit defaults below):
#   WATCH_DIR       - Directory to watch for new files
#   TAGGER_SCRIPT   - Path to tag_music.py
#   VENV_PATH       - Path to Python virtual environment
#   MODEL_DIR       - Path to Essentia models
#   LOG_DIR         - Directory for log files
# =============================================================================

set -e

# =============================================================================
# CONFIGURATION - Edit these to match your setup
# =============================================================================

# Directory to watch (where Picard moves files to)
WATCH_DIR="${WATCH_DIR:-/srv/dev-disk-by-uuid-dc4918d5-6597-465b-9567-ce442fbd8e2a/Media/Audio/Music/Sources/Clean}"

# Path to the tagger script
TAGGER_SCRIPT="${TAGGER_SCRIPT:-/opt/essentia-tagger/tag_music.py}"

# Python virtual environment path
VENV_PATH="${VENV_PATH:-/opt/essentia-tagger/venv}"

# Essentia models directory
MODEL_DIR="${MODEL_DIR:-/opt/essentia-tagger/models}"

# Log directory
LOG_DIR="${LOG_DIR:-/var/log/essentia-tagger}"

# Debounce time in seconds (wait for file operations to settle)
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-5}"

# Number of genres to tag
GENRES="${GENRES:-3}"

# Genre confidence threshold (percentage)
GENRE_THRESHOLD="${GENRE_THRESHOLD:-15}"

# Mood confidence threshold (percentage)
MOOD_THRESHOLD="${MOOD_THRESHOLD:-0.5}"

# Genre format: parent_child, child_parent, child_only, raw
GENRE_FORMAT="${GENRE_FORMAT:-parent_child}"

# Set to "true" for dry run mode (no tags written)
DRY_RUN="${DRY_RUN:-false}"

# Set to "true" to overwrite existing tags
OVERWRITE="${OVERWRITE:-true}"

# Audio file extensions to watch
AUDIO_EXTENSIONS="flac|mp3|ogg|oga|opus|m4a|m4b|mp4|aac|wma|aiff|aif|wav|wv|ape|mpc|mp\+|dsf"

# Watch mode: "inotify" (instant, local disks only) or "poll" (periodic scan).
# Use poll when WATCH_DIR is a network mount (NFS/SMB) written to by another
# machine - inotify never sees those changes.
WATCH_MODE="${WATCH_MODE:-inotify}"

# Poll mode: seconds between scans
POLL_INTERVAL="${POLL_INTERVAL:-300}"

# Poll mode: extra seconds each scan looks back past the previous one, to
# absorb clock skew between this machine and the NAS and slow copies
POLL_LOOKBACK="${POLL_LOOKBACK:-600}"

# Poll mode: persistent state (last scan time, processed files)
STATE_DIR="${STATE_DIR:-/var/lib/essentia-tagger}"

# Poll mode: seconds to keep processed-file entries (0 = keep forever).
# Must exceed POLL_INTERVAL + POLL_LOOKBACK or files get tagged twice.
PROCESSED_RETENTION="${PROCESSED_RETENTION:-86400}"

# Cooldown period in seconds (skip files processed within this time)
# Prevents feedback loop when tagger writes metadata back to the file
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-120}"

# =============================================================================
# DO NOT EDIT BELOW THIS LINE (unless you know what you're doing)
# =============================================================================

# Cache file for tracking recently processed files
PROCESSED_CACHE="/tmp/essentia-processed-cache"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"
}

log_info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $1"
}

# Check dependencies
check_dependencies() {
    log "Checking dependencies..."
    
    if [ "$WATCH_MODE" = "inotify" ] && ! command -v inotifywait &> /dev/null; then
        log_error "inotifywait not found. Install with: apt install inotify-tools"
        exit 1
    fi
    
    if [ ! -f "$TAGGER_SCRIPT" ]; then
        log_error "Tagger script not found: $TAGGER_SCRIPT"
        exit 1
    fi
    
    if [ ! -d "$VENV_PATH" ]; then
        log_error "Virtual environment not found: $VENV_PATH"
        log_info "Create it with: python3 -m venv $VENV_PATH"
        exit 1
    fi
    
    if [ ! -d "$MODEL_DIR" ]; then
        log_error "Model directory not found: $MODEL_DIR"
        exit 1
    fi
    
    if [ ! -d "$WATCH_DIR" ]; then
        log_error "Watch directory not found: $WATCH_DIR"
        exit 1
    fi
    
    if [ "$WATCH_MODE" != "inotify" ] && [ "$WATCH_MODE" != "poll" ]; then
        log_error "Invalid WATCH_MODE: $WATCH_MODE (use 'inotify' or 'poll')"
        exit 1
    fi

    if [ "$WATCH_MODE" = "poll" ] && [ "$PROCESSED_RETENTION" -ne 0 ] && \
       [ "$PROCESSED_RETENTION" -le $((POLL_INTERVAL + POLL_LOOKBACK)) ]; then
        log_error "PROCESSED_RETENTION ($PROCESSED_RETENTION) must be greater than POLL_INTERVAL + POLL_LOOKBACK ($((POLL_INTERVAL + POLL_LOOKBACK))), or 0 to keep forever"
        exit 1
    fi
    
    # Create log directory if needed
    mkdir -p "$LOG_DIR"
    
    log "All dependencies OK"
}

# Build the tagger command arguments
build_tagger_args() {
    local filepath="$1"
    local args=""
    
    args="--auto"
    args="$args --single-file"
    args="$args --genres $GENRES"
    args="$args --genre-threshold $GENRE_THRESHOLD"
    args="$args --mood-threshold $MOOD_THRESHOLD"
    args="$args --genre-format $GENRE_FORMAT"
    args="$args --model-dir $MODEL_DIR"
    args="$args --log-dir $LOG_DIR"
    
    if [ "$DRY_RUN" = "true" ]; then
        args="$args --dry-run"
    fi
    
    if [ "$OVERWRITE" = "true" ]; then
        args="$args --overwrite"
    fi
    
    echo "$args"
}

# Check if file was recently processed (prevents feedback loop)
is_recently_processed() {
    local filepath="$1"
    local current_time=$(date +%s)
    
    # Create cache file if it doesn't exist
    touch "$PROCESSED_CACHE" 2>/dev/null || true
    
    # Clean old entries from cache (older than cooldown period)
    local temp_cache=$(mktemp)
    while IFS='|' read -r timestamp file; do
        if [ -n "$timestamp" ] && [ -n "$file" ]; then
            local age=$((current_time - timestamp))
            if [ $age -lt $COOLDOWN_SECONDS ]; then
                echo "${timestamp}|${file}" >> "$temp_cache"
            fi
        fi
    done < "$PROCESSED_CACHE"
    mv "$temp_cache" "$PROCESSED_CACHE" 2>/dev/null || true
    
    # Check if file is in cache
    if grep -qF "|${filepath}" "$PROCESSED_CACHE" 2>/dev/null; then
        return 0  # File was recently processed
    fi
    return 1  # File not in cache
}

# Mark file as processed
mark_as_processed() {
    local filepath="$1"
    local current_time=$(date +%s)
    echo "${current_time}|${filepath}" >> "$PROCESSED_CACHE"
}

# Process a single file
process_file() {
    local filepath="$1"
    
    # Check if file still exists (might have been moved again)
    if [ ! -f "$filepath" ]; then
        log_warn "File no longer exists: $filepath"
        return 0
    fi
    
    # Check file extension
    local ext="${filepath##*.}"
    ext="${ext,,}"  # lowercase
    
    if [[ ! "$ext" =~ ^($AUDIO_EXTENSIONS)$ ]]; then
        log_info "Skipping non-audio file: $filepath"
        return 0
    fi
    
    # Check if file was recently processed (prevents feedback loop)
    if is_recently_processed "$filepath"; then
        log_info "Skipping (recently processed): $(basename "$filepath")"
        return 0
    fi
    
    log "Processing: $filepath"
    
    # Build arguments
    local args=$(build_tagger_args "$filepath")
    
    # Activate virtual environment and run tagger
    (
        source "$VENV_PATH/bin/activate"
        python3 "$TAGGER_SCRIPT" "$filepath" $args
    )
    
    local status=$?
    if [ $status -eq 0 ]; then
        log "Successfully tagged: $(basename "$filepath")"
        # Mark as processed to prevent feedback loop
        mark_as_processed "$filepath"
    else
        log_error "Failed to tag: $filepath (exit code: $status)"
    fi
    
    return $status
}

# Queue for debouncing
declare -A FILE_QUEUE
declare -A FILE_TIMESTAMPS

# Process the queue
process_queue() {
    local current_time=$(date +%s)
    
    for filepath in "${!FILE_QUEUE[@]}"; do
        local file_time="${FILE_TIMESTAMPS[$filepath]}"
        local age=$((current_time - file_time))
        
        if [ $age -ge $DEBOUNCE_SECONDS ]; then
            process_file "$filepath"
            unset FILE_QUEUE["$filepath"]
            unset FILE_TIMESTAMPS["$filepath"]
        fi
    done
}

# Add file to queue
queue_file() {
    local filepath="$1"
    FILE_QUEUE["$filepath"]=1
    FILE_TIMESTAMPS["$filepath"]=$(date +%s)
}

# Main watch loop
watch_directory() {
    log "Starting file watcher..."
    log "Watching: $WATCH_DIR"
    log "Tagger: $TAGGER_SCRIPT"
    log "Models: $MODEL_DIR"
    log "Logs: $LOG_DIR"
    log "Settings: genres=$GENRES, threshold=$GENRE_THRESHOLD%, format=$GENRE_FORMAT"
    log "Debounce: ${DEBOUNCE_SECONDS}s, Cooldown: ${COOLDOWN_SECONDS}s"
    echo ""
    log "Waiting for new files..."
    
    # Use inotifywait to watch for file events
    # -m = monitor mode (continuous)
    # -r = recursive
    # -e = events to watch
    # --format = output format
    inotifywait -m -r -e moved_to -e close_write --format '%w%f' "$WATCH_DIR" 2>/dev/null | while read filepath; do
        # Check if it's an audio file by extension
        local ext="${filepath##*.}"
        ext="${ext,,}"
        
        if [[ "$ext" =~ ^($AUDIO_EXTENSIONS)$ ]]; then
            log_info "Detected: $filepath"
            
            # Wait for debounce period to let file operations settle
            sleep "$DEBOUNCE_SECONDS"
            
            # Process the file
            process_file "$filepath"
        fi
    done
}

# Poll loop - for network mounts where inotify doesn't see remote writes
poll_directory() {
    local last_scan_file="$STATE_DIR/last-scan"
    local processed_file="$STATE_DIR/processed"
    
    mkdir -p "$STATE_DIR"
    touch "$processed_file"
    
    log "Starting poller..."
    log "Watching: $WATCH_DIR"
    log "Tagger: $TAGGER_SCRIPT"
    log "Models: $MODEL_DIR"
    log "Logs: $LOG_DIR"
    log "Settings: genres=$GENRES, threshold=$GENRE_THRESHOLD%, format=$GENRE_FORMAT"
    log "Interval: ${POLL_INTERVAL}s, Lookback: ${POLL_LOOKBACK}s, Settle: ${DEBOUNCE_SECONDS}s"
    log "State: $STATE_DIR"
    
    local last_scan
    if [ -s "$last_scan_file" ]; then
        last_scan=$(cat "$last_scan_file")
    else
        last_scan=$(date +%s)
        echo "$last_scan" > "$last_scan_file"
        log "First run - only files added from now on will be tagged"
    fi
    echo ""
    
    while true; do
        local since=$((last_scan - POLL_LOOKBACK))
        # Leave files changed in the last DEBOUNCE_SECONDS for the next scan,
        # they may still be copying
        local until=$(($(date +%s) - DEBOUNCE_SECONDS))
        
        # Match on ctime, not mtime: copies can preserve the source mtime, but
        # ctime is always set when the file lands on the NAS
        while IFS= read -r -d '' filepath; do
            # Skip files already processed in this exact state. The tagger's
            # own writes change ctime, so they show up here again.
            local sig
            sig=$(stat -c '%Y %s' "$filepath" 2>/dev/null) || continue
            if grep -qxF "${sig}|${filepath}" "$processed_file"; then
                continue
            fi
            
            log_info "Detected: $filepath"
            # </dev/null so the tagger can't consume the file list
            if ! process_file "$filepath" </dev/null; then
                log_warn "Not retrying until the file changes: $filepath"
            fi
            
            # Record the post-tagging state so the rewrite isn't picked up again
            sig=$(stat -c '%Y %s' "$filepath" 2>/dev/null) || continue
            echo "${sig}|${filepath}" >> "$processed_file"
        done < <(find "$WATCH_DIR" -type f \
                    -newerct "@$since" ! -newerct "@$until" \
                    -regextype posix-extended -iregex ".*\.($AUDIO_EXTENSIONS)" \
                    -print0)
        
        last_scan=$until
        echo "$last_scan" > "$last_scan_file"

        # Drop entries by their recorded mtime. Once past the scan window a
        # file only reappears if it changes, and then its entry no longer
        # matches anyway.
        if [ "$PROCESSED_RETENTION" -ne 0 ]; then
            awk -v cutoff=$(($(date +%s) - PROCESSED_RETENTION)) '$1 >= cutoff' \
                "$processed_file" > "$processed_file.tmp" && \
                mv "$processed_file.tmp" "$processed_file"
        fi

        sleep "$POLL_INTERVAL"
    done
}

# Start watching using the configured mode
start_watching() {
    if [ "$WATCH_MODE" = "poll" ]; then
        poll_directory
    else
        watch_directory
    fi
}

# Print help
show_help() {
    cat << EOF
Essentia File Watcher for MusicBrainz Picard Integration

Usage: $0 [options]

Options:
    -h, --help          Show this help message
    -c, --check         Check dependencies only
    -t, --test          Test mode - process existing files then exit
    -d, --dry-run       Enable dry run mode (no tags written)
    -r, --reset-cache   Clear processed files cache (force reprocessing)
                        In poll mode, files changed within the lookback window
                        will be tagged again

Environment Variables:
    WATCH_DIR       Directory to watch (default: $WATCH_DIR)
    WATCH_MODE      'inotify' or 'poll' - use poll for NFS/SMB mounts (default: inotify)
    POLL_INTERVAL   Poll mode: seconds between scans (default: 300)
    POLL_LOOKBACK   Poll mode: scan overlap for clock skew (default: 600)
    STATE_DIR       Poll mode: persistent state dir (default: /var/lib/essentia-tagger)
    PROCESSED_RETENTION Poll mode: seconds to remember tagged files, 0 = forever (default: 86400)
    TAGGER_SCRIPT   Path to tag_music.py
    VENV_PATH       Path to Python venv
    MODEL_DIR       Path to Essentia models
    LOG_DIR         Directory for logs
    DEBOUNCE_SECONDS    Wait time before processing (default: 5)
    COOLDOWN_SECONDS    Skip files processed within this time (default: 120)
    GENRES          Number of genres (default: 3)
    GENRE_THRESHOLD Genre confidence % (default: 15)
    MOOD_THRESHOLD  Mood confidence % (default: 0.5)
    GENRE_FORMAT    Format style (default: parent_child)
    DRY_RUN         Set to 'true' for dry run
    OVERWRITE       Set to 'true' to overwrite existing tags

Examples:
    # Start watching
    $0
    
    # Check dependencies
    $0 --check
    
    # Test with dry run
    DRY_RUN=true $0 --test
    
    # Clear cache to force reprocessing
    $0 --reset-cache
    
    # Override settings
    GENRES=4 GENRE_THRESHOLD=20 $0
    
    # Poll a network mount every 5 minutes
    WATCH_MODE=poll $0
    
    # Shorter cooldown period (default 120s)
    COOLDOWN_SECONDS=60 $0

EOF
}

# Test mode - process existing files
test_mode() {
    log "Test mode - scanning for existing audio files..."
    
    # Clear cache for test mode so files get reprocessed
    rm -f "$PROCESSED_CACHE"
    
    find "$WATCH_DIR" -type f \( -iname "*.flac" -o -iname "*.mp3" -o -iname "*.ogg" -o -iname "*.m4a" -o -iname "*.wav" \) | head -5 | while read filepath; do
        process_file "$filepath"
    done
    
    log "Test complete"
}

# Main entry point
main() {
    case "${1:-}" in
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--check)
            check_dependencies
            exit 0
            ;;
        -t|--test)
            check_dependencies
            test_mode
            exit 0
            ;;
        -r|--reset-cache)
            rm -f "$PROCESSED_CACHE" "$STATE_DIR/processed"
            log "Processed files cache cleared"
            exit 0
            ;;
        -d|--dry-run)
            DRY_RUN="true"
            check_dependencies
            start_watching
            ;;
        "")
            check_dependencies
            start_watching
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
}

# Trap signals for clean shutdown
trap 'log "Shutting down..."; exit 0' SIGTERM SIGINT

# Run main
main "$@"
