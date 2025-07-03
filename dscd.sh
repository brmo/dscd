#!/bin/bash

########################################
# Default configuration values
########################################
BASE_DIR=""                    # Initialize empty variable
LOG_FILE="/tmp/dscd.log"       # Default log file name
PRUNE=0                        # Default prune setting
GRACEFUL=0                     # Default graceful setting
TMPRESTART="/tmp/dscd.restart" # Default log file for graceful setting
REMOTE_BRANCH="main"           # Default remote branch name
COMPOSE_OPTS=""                # Additional options for docker compose

########################################
# Functions
########################################

log_message() {
    local message="$1"
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $message" | tee -a "$LOG_FILE"
}

update_compose_files() {
    local dir="$1"

    cd "$dir" || {
        log_message "ERROR: Directory doesn't exist, exiting..."
        exit 127
    }

    # Make sure we're in a git repo
    if [ ! -d .git ]; then
        log_message "ERROR: Directory is not a git repository, exiting..."
        exit 1
    else
        log_message "INFO:  Git repository found!"
    fi

    # Check if there are any changes in the Git repository
    if ! git fetch --quiet origin; then
        log_message "ERROR: Unable to fetch changes from the remote repository (the server may be offline or unreachable)"
        exit 1
    fi

    local_hash=$(git rev-parse HEAD)
    remote_hash=$(git rev-parse "origin/$REMOTE_BRANCH")
    log_message "INFO:  Local hash is  $local_hash"
    log_message "INFO:  Remote hash is $remote_hash"

    # Check for uncommitted local changes
    uncommitted_changes=$(git status --porcelain)
    if [ -n "$uncommitted_changes" ]; then
        log_message "ERROR: Uncommitted changes detected in $dir, exiting..."
        exit 1
    fi

    # Check if the local hash matches the remote hash
    if [ "$local_hash" != "$remote_hash" ]; then
        log_message "STATE: Hashes don't match, updating..."

        # Pull any changes in the Git repository
        if ! git pull --quiet origin "$REMOTE_BRANCH"; then
            log_message "ERROR: Unable to pull changes from the remote repository (the server may be offline or unreachable)"
            exit 1
        fi

        redeploy_compose_file() {
            local file=$1

            # Build the command based on whether we have extra options
            run_compose_command() {
                local cmd_args="$1"
                if [ -n "$COMPOSE_OPTS" ]; then
                    eval "docker stack deploy $COMPOSE_OPTS $cmd_args"
                else
                    eval "docker stack deploy $cmd_args"
                fi
            }

            if [ $GRACEFUL -eq 1 ]; then
                run_compose_command "-f \"$file\" up -d --dry-run" &> $TMPRESTART
                if grep -q "Recreate" $TMPRESTART; then
                    log_message "GRACEFUL: Redeploying compose file for $file"
                    run_compose_command "-f \"$file\" up -d --quiet-pull"
                else
                    log_message "GRACEFUL: Skipping Redeploying compose file for $file (no change)"
                fi
            else
                log_message "STATE: Redeploying compose file for $file"
                run_compose_command "-f \"$file\" up -d --quiet-pull"
            fi
        }

        find . -type f \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yaml' -o -name 'compose.yml' \) | sort | while IFS= read -r file; do
            # Extract the directory containing the file
            dir=$(dirname "$file")

            # If EXCLUDE is set
            if [ -n "$EXCLUDE" ]; then
                # If the directory does not contain the exclude pattern
                if [[ "$dir" != *"$EXCLUDE"* ]]; then
                    redeploy_compose_file "$file"
                fi
            else
                redeploy_compose_file "$file"
            fi
        done
    else
        log_message "STATE: Hashes match, so nothing to do"
    fi

    # Check if PRUNE is provided
    if [ $PRUNE -eq 1 ]; then
        log_message "STATE: Pruning images"
        docker image prune --all --force
    fi

    # Cleanup graceful file.
    if [ $GRACEFUL -eq 1 ]; then
        rm -f $TMPRESTART
    fi

    log_message "STATE: Done!"
}

usage() {
    printf "
    Usage: $0 [OPTIONS]

    Options:
      -b <name>       Specify the remote branch to track (default: main)
      -d <path>       Specify the base directory of the git repository (required)
      -g              Graceful, only restart containers that will be recreated (optional)
      -h              Show this help message
      -l <path>       Specify the path to the log file (default: /tmp/dccd.log)
      -o <options>    Additional options to pass directly to \`docker compose...\` (optional)
      -p              Specify if you want to prune docker images (default: don't prune)
      -x <path>       Exclude directories matching the specified pattern (optional - relative to the base directory)
      
    Example: /path/to/dccd.sh -b master -d /path/to/git_repo -g -l /tmp/dccd.txt -o \"--env-file /path/to/my.env\" -p -x ignore_this_directory

"
    exit 1
}

########################################
# Options
########################################

while getopts ":b:d:ghl:o:px:" opt; do
    case "$opt" in
    b)
        REMOTE_BRANCH="$OPTARG"
        ;;
    d)
        BASE_DIR="$OPTARG"
        ;;
    g)
        GRACEFUL=1
        ;;
    h)
        usage
        ;;
    l)
        LOG_FILE="$OPTARG"
        ;;
    o)
        COMPOSE_OPTS="$OPTARG"
        ;;
    p)
        PRUNE=1
        ;;
    x)
        EXCLUDE="$OPTARG"
        ;;
    \?)
        echo "Invalid option: -$OPTARG" >&2
        usage
        ;;
    :)
        echo "Option -$OPTARG requires an argument." >&2
        usage
        ;;
    esac
done

########################################
# Script starts here
########################################

touch "$LOG_FILE"
{
    echo "########################################"
    echo "# Starting!"
    echo "########################################"
} >> "$LOG_FILE"

# Check if BASE_DIR is provided
if [ -z "$BASE_DIR" ]; then
    log_message "ERROR: The base directory (-d) is required, exiting..."
    usage
else
    log_message "INFO:  Base directory is set to $BASE_DIR"
fi

# Check if REMOTE_BRANCH is provided
if [ -z "$REMOTE_BRANCH" ]; then
    log_message "INFO:  The remote branch isn't specified, so using $REMOTE_BRANCH"
else
    log_message "INFO:  The remote branch is set to $REMOTE_BRANCH"
fi

# Check if COMPOSE_OPTS is provided
if [ -n "$COMPOSE_OPTS" ]; then
    log_message "INFO:  Using additional docker compose options: $COMPOSE_OPTS"
fi

# Check if EXCLUDE is provided
if [ -n "$EXCLUDE" ]; then
    log_message "INFO:  Will be excluding pattern $EXCLUDE"
fi

update_compose_files "$BASE_DIR"
