#!/bin/bash

# Script to download a Docker image (manifest, config, layers) from a GitLab Container Registry.
# Requires curl and jq.

set -e # Exit immediately if a command exits with a non-zero status.
# set -x # Debug mode

usage() {
    echo "Usage: $0 -r <registry_url> -i <image_path> -t <image_tag> -k <token> [-U <username>] [-o <output_directory>] [-A <auth_realm>] [-S <auth_service>]"
    echo "  -r REGISTRY_URL:      FQDN of the GitLab Container Registry (e.g., registry.gitlab.com)"
    echo "  -i IMAGE_PATH:        Full path of the image (e.g., mygroup/myproject/myimage)"
    echo "  -t IMAGE_TAG:         Tag of the image (e.g., latest, 1.0.0)"
    echo "  -k TOKEN:             GitLab Token (PAT, Deploy Token, CI Job Token) with read_registry scope"
    echo "  -U USERNAME:          Optional. Username for Basic Authentication. If provided, TOKEN is used as the password."
    echo "  -o OUTPUT_DIRECTORY:  Optional. Directory to save image components (default: ./docker_image_download)"
    echo "  -A AUTH_REALM:        Optional. Override URL for the token authentication server (realm)."
    echo "  -S AUTH_SERVICE:      Optional. Override service name for token authentication."
    exit 1
}

# --- Function to discover Www-Authenticate parameters (realm, service) ---
discover_auth_params() {
    echo "Attempting to discover authentication parameters from $REGISTRY_URL..."
    local discovery_url="https://$REGISTRY_URL/v2/"
    local auth_header_file
    auth_header_file=$(mktemp) # Ensure mktemp is available or use a fixed temp file name with cleanup

    # Make a HEAD request to get headers without downloading body
    # Use initial TOKEN for this discovery if available, as some registries might require it even for the /v2/ endpoint
    local discovery_auth_opts
    if [ -n "$USERNAME" ]; then
        discovery_auth_opts=(-u "$USERNAME:$TOKEN")
    elif [ -n "$TOKEN" ]; then # If only token is provided, use as bearer for discovery
        discovery_auth_opts=(-H "Authorization: Bearer $TOKEN")
    else
        # No auth provided for discovery, proceed unauthenticated
        discovery_auth_opts=()
    fi

    # We don't care about the body, just the headers, specifically Www-Authenticate on a 401
    # curl -I only gives http_code 000 with -w, so use -D to dump headers and check status
    local discovery_http_status
    discovery_http_status=$(curl -sSL -w "%{http_code}" \
        "${discovery_auth_opts[@]}" \
        -D "$auth_header_file" \
        -o /dev/null \
        "$discovery_url")

    if [ "$discovery_http_status" -eq 401 ]; then
        echo "Received 401 from $discovery_url, attempting to parse Www-Authenticate header."
        local www_authenticate_header
        www_authenticate_header=$(grep -i '^Www-Authenticate:' "$auth_header_file" | head -n 1)

        if [ -n "$www_authenticate_header" ]; then
            echo "Www-Authenticate header: $www_authenticate_header"
            # Example: Www-Authenticate: Bearer realm=\"https://gitlab.example.com/jwt/auth\",service=\"container_registry\"
            # Using sed for extraction. This regex assumes realm and service are quoted.
            TOKEN_REALM=$(echo "$www_authenticate_header" | sed -n 's/.*realm=\"\([^\"]*\)\".*/\1/p')
            TOKEN_SERVICE=$(echo "$www_authenticate_header" | sed -n 's/.*service=\"\([^\"]*\)\".*/\1/p')
            
            if [ -n "$TOKEN_REALM" ]; then
                echo "Discovered Realm: $TOKEN_REALM"
            else
                echo "Warning: Could not parse realm from Www-Authenticate header." >&2
            fi
            if [ -n "$TOKEN_SERVICE" ]; then
                echo "Discovered Service: $TOKEN_SERVICE"
            else
                # Service might be optional or not present in all Www-Authenticate headers for some flows.
                # Defaulting to 'container_registry' if not found, as it's common for GitLab.
                echo "Warning: Could not parse service from Www-Authenticate header. Defaulting to 'container_registry'." >&2
                TOKEN_SERVICE="container_registry"
            fi
        else
            echo "Warning: Received 401 but Www-Authenticate header not found or empty." >&2
        fi
    elif [ "$discovery_http_status" -ge 200 ] && [ "$discovery_http_status" -lt 300 ]; then
        echo "Info: Received $discovery_http_status from $discovery_url. This registry might not require JWT auth or allows anonymous pulls for this path." >&2
        echo "Proceeding without specific realm/service discovery. If JWT is needed later, it might fail." >&2
    else
        echo "Warning: Failed to discover auth params from $discovery_url. HTTP Status: $discovery_http_status" >&2
        echo "Headers received:" >&2
        cat "$auth_header_file" >&2
    fi
    rm -f "$auth_header_file"
}

OUTPUT_DIR="./docker_image_download"
USERNAME=""
CMD_TOKEN_REALM="" # For command-line provided realm
CMD_TOKEN_SERVICE="" # For command-line provided service

while getopts ":r:i:t:k:U:o:A:S:" opt; do
    case ${opt} in
        r) REGISTRY_URL=$OPTARG ;; 
        i) IMAGE_PATH=$OPTARG ;;  
        t) IMAGE_TAG=$OPTARG ;;   
        k) TOKEN=$OPTARG ;;       
        U) USERNAME=$OPTARG ;;   
        o) OUTPUT_DIR=$OPTARG ;;  
        A) CMD_TOKEN_REALM=$OPTARG ;; 
        S) CMD_TOKEN_SERVICE=$OPTARG ;; 
        \?) echo "Invalid option: $OPTARG" 1>&2; usage ;; 
        :) echo "Invalid option: $OPTARG requires an argument" 1>&2; usage ;; 
    esac
done

if [ -z "$REGISTRY_URL" ] || [ -z "$IMAGE_PATH" ] || [ -z "$IMAGE_TAG" ] || [ -z "$TOKEN" ]; then
    echo "Error: Missing mandatory arguments."
    usage
fi

# --- JWT Authentication Flow Variables ---
REGISTRY_JWT=""
TOKEN_REALM=""       # Will be discovered or set by command line
TOKEN_SERVICE=""    # Will be discovered or set by command line
# The scope will be constructed dynamically later using IMAGE_PATH

# Discover auth parameters first, then apply command-line overrides
discover_auth_params # This will populate TOKEN_REALM and TOKEN_SERVICE if discovery is successful

if [ -n "$CMD_TOKEN_REALM" ]; then
    echo "Overriding discovered/default TOKEN_REALM with command-line value: $CMD_TOKEN_REALM"
    TOKEN_REALM="$CMD_TOKEN_REALM"
fi

if [ -n "$CMD_TOKEN_SERVICE" ]; then
    echo "Overriding discovered/default TOKEN_SERVICE with command-line value: $CMD_TOKEN_SERVICE"
    TOKEN_SERVICE="$CMD_TOKEN_SERVICE"
fi

# After discovery and potential overrides, check if TOKEN_REALM is set.
# TOKEN_SERVICE might be optional for some auth flows, but realm is critical for JWT.
if [ -z "$TOKEN_REALM" ]; then
    echo "Error: Token Authentication Realm (TOKEN_REALM) is not set." >&2
    echo "It could not be discovered, and was not provided via the -A option." >&2
    echo "Cannot proceed with JWT authentication." >&2
    exit 1
fi

# If TOKEN_SERVICE is still empty after discovery and override, set a common default.
# Some registries might not explicitly state the service in Www-Authenticate for /v2/ endpoint
# but require it for the token request.
if [ -z "$TOKEN_SERVICE" ]; then
    echo "Warning: TOKEN_SERVICE is not set. Defaulting to 'container_registry'. Provide -S if this is incorrect." >&2
    TOKEN_SERVICE="container_registry"
fi

echo "Using TOKEN_REALM: $TOKEN_REALM"
echo "Using TOKEN_SERVICE: $TOKEN_SERVICE"

# Authentication options for the JWT Token Server (realm)
# This uses the -U and -k parameters supplied to the script
declare -a JWT_SERVER_AUTH_OPTS
if [ -n "$USERNAME" ]; then
    JWT_SERVER_AUTH_OPTS=(-u "$USERNAME:$TOKEN")
else
    # If no username, assume the token is a Bearer token for the JWT server
    # This might need adjustment if the JWT server *requires* Basic Auth
    JWT_SERVER_AUTH_OPTS=(-H "Authorization: Bearer $TOKEN")
fi

# Check for dependencies
if ! command -v curl &> /dev/null; then
    echo "Error: curl is not installed. Please install curl." >&2
    exit 1
fi
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install jq." >&2
    exit 1
fi

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"
echo "Image components will be saved to: $(realpath "$OUTPUT_DIR")"

# --- Helper function for curl requests ---
# $1: URL
# $2: Output file path (optional, if not provided, output to stdout)
# $3: Extra headers (optional, e.g. "Accept: application/json")
# Returns HTTP status code via stdout if no output file, or writes to file and echoes status code.
# Saves response headers to a temporary file for inspection.

    # For push, scope would be "repository:$IMAGE_PATH:pull,push"

    local jwt_url="$TOKEN_REALM?service=$TOKEN_SERVICE&scope=$scope"

    echo "Requesting JWT from: $jwt_url"
    echo "Using JWT server auth options: ${JWT_SERVER_AUTH_OPTS[*]}"

    # Make the request to the JWT server
    # We need to capture the output and the HTTP status code
    local jwt_response_body_and_status
    jwt_response_body_and_status=$(curl -sSL -w "\n%{http_code}" \
        "${JWT_SERVER_AUTH_OPTS[@]}" \
        -H "Accept: application/json" \
        "$jwt_url")
    
    local jwt_response_body=$(echo "$jwt_response_body_and_status" | sed '$d') # all but last line
    local jwt_http_status=$(echo "$jwt_response_body_and_status" | tail -n1)   # last line

    if [ "$jwt_http_status" -ne 200 ]; then
        echo "Error: Failed to fetch JWT. HTTP Status: $jwt_http_status" >&2
        echo "Response from JWT server: $jwt_response_body" >&2
        echo "Realm: $TOKEN_REALM" >&2
        echo "Service: $TOKEN_SERVICE" >&2
        echo "Scope: $scope" >&2
        echo "Auth used: ${JWT_SERVER_AUTH_OPTS[*]}" >&2
        # Consider if script should exit here or let the caller handle it
        return 1 # Indicate failure
    fi

    REGISTRY_JWT=$(echo "$jwt_response_body" | jq -r '.token // .access_token')

    if [ -z "$REGISTRY_JWT" ] || [ "$REGISTRY_JWT" == "null" ]; then
        echo "Error: JWT not found or was null in response from token server." >&2
        echo "Response body: $jwt_response_body" >&2
        REGISTRY_JWT=""
        return 1 # Indicate failure
    fi

    echo "Successfully fetched JWT."
    return 0 # Indicate success
}

RESPONSE_HEADERS_FILE=$(mktemp)

make_request() {
    local url="$1"
    local output_file="$2"
    local extra_accept_header="$3"
    local attempt_count=1
    local max_attempts=2 # Try initial, then one retry after JWT refresh
    local http_status
    local response_body # Declare here for wider scope within the function

    while [ "$attempt_count" -le "$max_attempts" ]; do
        if [ -z "$REGISTRY_JWT" ]; then
            echo "No active JWT. Fetching for request to $url..."
            if ! fetch_registry_jwt; then
                echo "Error: Failed to obtain JWT. Cannot make request to $url." >&2
                if [ -n "$output_file" ]; then echo "503"; else echo "{\"error\":\"JWT fetch failed\"}"; fi
                return 1 # General failure for make_request
            fi
        fi

        local current_auth_opts=(-H "Authorization: Bearer $REGISTRY_JWT")
        local current_accept_header="application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json"
        if [ -n "$extra_accept_header" ]; then
            current_accept_header="$extra_accept_header"
        fi

        echo "Making request (Attempt $attempt_count) to: $url"
        if [ -n "$output_file" ]; then
            http_status=$(curl -sSL -w "%{http_code}" \
                "${current_auth_opts[@]}" \
                -H "Accept: $current_accept_header" \
                -D "$RESPONSE_HEADERS_FILE" \
                -o "$output_file" \
                "$url")
        else
            local response_body_and_status
            response_body_and_status=$(curl -sSL -w "\n%{http_code}" \
                "${current_auth_opts[@]}" \
                -H "Accept: $current_accept_header" \
                -D "$RESPONSE_HEADERS_FILE" \
                "$url")
            response_body=$(echo "$response_body_and_status" | sed '$d')
            http_status=$(echo "$response_body_and_status" | tail -n1)
        fi

        if [ "$http_status" -eq 401 ] && [ "$attempt_count" -lt "$max_attempts" ]; then
            echo "Received 401 (Unauthorized) on attempt $attempt_count for $url. JWT might be invalid or expired. Attempting refresh..." >&2
            REGISTRY_JWT="" # Clear current JWT to force re-fetch
            # fetch_registry_jwt will be called at the start of the next loop iteration if REGISTRY_JWT is empty.
        elif [ "$http_status" -eq 401 ] && [ "$attempt_count" -eq "$max_attempts" ]; then
            echo "Error: Received 401 (Unauthorized) for $url after JWT refresh. Giving up." >&2
            # Fall through to handle final status outside loop
            break
        else
            # Not a 401, or it's a 401 on the last attempt (which is handled above), or successful.
            break
        fi
        attempt_count=$((attempt_count + 1))
    done

    # Final handling of output and return status
    if [ -n "$output_file" ]; then
        echo "$http_status" # Echo status code, content is in file
        if [ "$http_status" -lt 200 ] || [ "$http_status" -ge 300 ]; then
            return 1 # Indicate failure to the caller via exit code
        fi
    else
        # No output file, echo body to stdout.
        echo "$response_body"
        if [ "$http_status" -lt 200 ] || [ "$http_status" -ge 300 ]; then
            echo "Error: make_request to $url (no output file) received HTTP status $http_status. Body above may contain details." >&2
            return 1 # Indicate failure to the caller via exit code
        fi
    fi
    return 0 # Success
}

# 1. Fetch the manifest
MANIFEST_URL="https://$REGISTRY_URL/v2/$IMAGE_PATH/manifests/$IMAGE_TAG"
echo "Fetching manifest from: $MANIFEST_URL"

MANIFEST_FILE_TMP="$OUTPUT_DIR/manifest_initial_response.json"
# Call make_request and capture its stdout (which is the HTTP status code for file output)
HTTP_STATUS=$(make_request "$MANIFEST_URL" "$MANIFEST_FILE_TMP")
MAKE_REQUEST_EXIT_STATUS=$?

# Check the exit status of make_request first
if [ "$MAKE_REQUEST_EXIT_STATUS" -ne 0 ]; then
    echo "Error: make_request function failed to fetch manifest. See errors above." >&2
    # HTTP_STATUS might contain an error code from the last attempt, or a generic one from make_request
    echo "Final reported HTTP status (if available): $HTTP_STATUS" >&2
    echo "Response headers (if available from last attempt):" >&2
    cat "$RESPONSE_HEADERS_FILE" >&2
    echo "Response body (if available from last attempt):" >&2
    cat "$MANIFEST_FILE_TMP" 2>/dev/null || echo "(no body file or not readable)" >&2
    rm -f "$RESPONSE_HEADERS_FILE" "$MANIFEST_FILE_TMP"
    exit 1
fi

# If make_request succeeded (exit status 0), HTTP_STATUS should be 2xx.
# The explicit check below is a safeguard.
if [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ]; then
    echo "Error: Failed to fetch manifest. HTTP Status: $HTTP_STATUS" >&2
    echo "Response headers:" >&2
    cat "$RESPONSE_HEADERS_FILE" >&2
    echo "Response body:" >&2
    cat "$MANIFEST_FILE_TMP" >&2
    if [ "$HTTP_STATUS" -eq 401 ]; then
        echo "Warning: Received 401 (Unauthorized). Ensure your token is correct, has 'read_registry' scope, and is not expired." >&2
    fi
    rm -f "$RESPONSE_HEADERS_FILE" "$MANIFEST_FILE_TMP"
    exit 1
fi

# Determine manifest media type from Content-Type header or from the manifest content itself
MANIFEST_MEDIA_TYPE=$(grep -i '^Content-Type:' "$RESPONSE_HEADERS_FILE" | awk '{print $2}' | tr -d '\r' || echo "")
if [ -z "$MANIFEST_MEDIA_TYPE" ] || [[ "$MANIFEST_MEDIA_TYPE" != application* ]]; then # Fallback if header is weird
    MANIFEST_MEDIA_TYPE=$(jq -r '.mediaType' "$MANIFEST_FILE_TMP" 2>/dev/null || echo "")
fi
echo "Initial manifest media type: $MANIFEST_MEDIA_TYPE"

ACTUAL_MANIFEST_CONTENT_FILE="$OUTPUT_DIR/image_manifest.json" # Default name
SELECTED_MANIFEST_DIGEST=""

if [[ "$MANIFEST_MEDIA_TYPE" == "application/vnd.docker.distribution.manifest.list.v2+json" || "$MANIFEST_MEDIA_TYPE" == "application/vnd.oci.image.index.v1+json" ]]; then
    echo "Detected a manifest list (multi-architecture image)."
    mv "$MANIFEST_FILE_TMP" "$OUTPUT_DIR/manifest_list.json"
    echo "Manifest list saved to $OUTPUT_DIR/manifest_list.json"

    # Try to find linux/amd64
    SELECTED_MANIFEST_DIGEST=$(jq -r '.manifests[] | select(.platform.architecture=="amd64" and .platform.os=="linux") | .digest' "$OUTPUT_DIR/manifest_list.json" 2>/dev/null | head -n 1)

    if [ -z "$SELECTED_MANIFEST_DIGEST" ]; then
        echo "Warning: Could not find a linux/amd64 manifest. Using the first available manifest in the list."
        SELECTED_MANIFEST_DIGEST=$(jq -r '.manifests[0].digest' "$OUTPUT_DIR/manifest_list.json" 2>/dev/null | head -n 1)
    fi

    if [ -z "$SELECTED_MANIFEST_DIGEST" ]; then
        echo "Error: Could not find any manifest digest in the manifest list." >&2
        rm -f "$RESPONSE_HEADERS_FILE"
        exit 1
    fi
    echo "Selected manifest digest from list: $SELECTED_MANIFEST_DIGEST"

    SPECIFIC_MANIFEST_URL="https://$REGISTRY_URL/v2/$IMAGE_PATH/manifests/$SELECTED_MANIFEST_DIGEST"
    ACTUAL_MANIFEST_CONTENT_FILE="$OUTPUT_DIR/$(echo $SELECTED_MANIFEST_DIGEST | tr ':' '_')_manifest.json"
    
    echo "Fetching specific architecture manifest ($SELECTED_MANIFEST_DIGEST) from: $SPECIFIC_MANIFEST_URL"
    HTTP_STATUS=$(make_request "$SPECIFIC_MANIFEST_URL" "$ACTUAL_MANIFEST_CONTENT_FILE" "application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json")
    MAKE_REQUEST_EXIT_STATUS=$?

    if [ "$MAKE_REQUEST_EXIT_STATUS" -ne 0 ]; then
        echo "Error: make_request function failed to fetch specific architecture manifest $SELECTED_MANIFEST_DIGEST. See errors above." >&2
        echo "Final reported HTTP status (if available): $HTTP_STATUS" >&2
        echo "Response headers (if available from last attempt):" >&2
        cat "$RESPONSE_HEADERS_FILE" >&2
        echo "Response body (if available from last attempt):" >&2
        cat "$ACTUAL_MANIFEST_CONTENT_FILE" 2>/dev/null || echo "(no body file or not readable)" >&2
        rm -f "$RESPONSE_HEADERS_FILE" "$ACTUAL_MANIFEST_CONTENT_FILE"
        exit 1
    fi

    # If make_request succeeded (exit status 0), HTTP_STATUS should be 2xx.
    if [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ]; then
        echo "Error: Failed to fetch specific architecture manifest $SELECTED_MANIFEST_DIGEST. HTTP Status: $HTTP_STATUS" >&2
        echo "Response headers:" >&2
        cat "$RESPONSE_HEADERS_FILE" >&2
        echo "Response body:" >&2
        cat "$ACTUAL_MANIFEST_CONTENT_FILE" >&2
        rm -f "$RESPONSE_HEADERS_FILE" "$ACTUAL_MANIFEST_CONTENT_FILE"
        exit 1
    fi
elif [[ "$MANIFEST_MEDIA_TYPE" == "application/vnd.docker.distribution.manifest.v2+json" || "$MANIFEST_MEDIA_TYPE" == "application/vnd.oci.image.manifest.v1+json" ]]; then
    echo "Detected a single architecture image manifest."
    mv "$MANIFEST_FILE_TMP" "$ACTUAL_MANIFEST_CONTENT_FILE"
else
    echo "Error: Unsupported manifest media type: $MANIFEST_MEDIA_TYPE" >&2
    echo "Problematic manifest content saved to $MANIFEST_FILE_TMP for debugging." >&2
    # mv "$MANIFEST_FILE_TMP" "$OUTPUT_DIR/unknown_manifest_type.json" # Keep it with a more descriptive name
    rm -f "$RESPONSE_HEADERS_FILE"
    exit 1
fi

echo "Final image manifest saved to $ACTUAL_MANIFEST_CONTENT_FILE"

# 2. Download the image configuration blob
CONFIG_DIGEST=$(jq -r '.config.digest' "$ACTUAL_MANIFEST_CONTENT_FILE")
if [ -z "$CONFIG_DIGEST" ] || [ "$CONFIG_DIGEST" == "null" ]; then
    echo "Error: Could not parse config digest from manifest $ACTUAL_MANIFEST_CONTENT_FILE" >&2
    rm -f "$RESPONSE_HEADERS_FILE"
    exit 1
fi

CONFIG_URL="https://$REGISTRY_URL/v2/$IMAGE_PATH/blobs/$CONFIG_DIGEST"
CONFIG_FILE_NAME="$(echo $CONFIG_DIGEST | tr ':' '_').json"
CONFIG_OUTPUT_PATH="$OUTPUT_DIR/$CONFIG_FILE_NAME"

echo "Downloading image config ($CONFIG_DIGEST) from: $CONFIG_URL"
HTTP_STATUS=$(make_request "$CONFIG_URL" "$CONFIG_OUTPUT_PATH" "application/octet-stream") # Config is often JSON but can be requested as octet-stream
MAKE_REQUEST_EXIT_STATUS=$?

if [ "$MAKE_REQUEST_EXIT_STATUS" -ne 0 ]; then
    echo "Error: make_request function failed to download image config blob $CONFIG_DIGEST. See errors above." >&2
    echo "Final reported HTTP status (if available): $HTTP_STATUS" >&2
    echo "Response headers (if available from last attempt):" >&2
    cat "$RESPONSE_HEADERS_FILE" >&2
    echo "Response body (if available from last attempt):" >&2
    cat "$CONFIG_OUTPUT_PATH" 2>/dev/null || echo "(no body file or not readable)" >&2
    rm -f "$RESPONSE_HEADERS_FILE" "$CONFIG_OUTPUT_PATH"
    exit 1
fi

# If make_request succeeded (exit status 0), HTTP_STATUS should be 2xx.
if [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ]; then
    echo "Error: Failed to download image config blob $CONFIG_DIGEST. HTTP Status: $HTTP_STATUS" >&2
    echo "Response headers:" >&2
    cat "$RESPONSE_HEADERS_FILE" >&2
    echo "Response body (if available from last attempt):" >&2
    cat "$CONFIG_OUTPUT_PATH" 2>/dev/null || echo "(no body file or not readable)" >&2
    rm -f "$RESPONSE_HEADERS_FILE" "$CONFIG_OUTPUT_PATH"
    exit 1
fi
echo "Image config saved to $CONFIG_OUTPUT_PATH"

# 3. Download layers
LAYERS_DIR="$OUTPUT_DIR/layers"
mkdir -p "$LAYERS_DIR"

LAYER_COUNT=$(jq -r '.layers | length' "$ACTUAL_MANIFEST_CONTENT_FILE")
echo "Downloading $LAYER_COUNT layers to: $LAYERS_DIR"

jq -c '.layers[]' "$ACTUAL_MANIFEST_CONTENT_FILE" | while IFS= read -r layer_obj; do
    LAYER_DIGEST=$(echo "$layer_obj" | jq -r '.digest')
    LAYER_MEDIA_TYPE=$(echo "$layer_obj" | jq -r '.mediaType')
    LAYER_SIZE=$(echo "$layer_obj" | jq -r '.size')

    LAYER_URL="https://$REGISTRY_URL/v2/$IMAGE_PATH/blobs/$LAYER_DIGEST"
    
    LAYER_FILE_NAME="$(echo $LAYER_DIGEST | tr ':' '_')"
    if [[ "$LAYER_MEDIA_TYPE" == *"tar+gzip"* || "$LAYER_MEDIA_TYPE" == *"tar.gzip"* ]]; then
        LAYER_FILE_NAME+=".tar.gz"
    elif [[ "$LAYER_MEDIA_TYPE" == *"tar"* ]]; then
        LAYER_FILE_NAME+=".tar"
    else
        LAYER_FILE_NAME+=".blob"
        echo "Warning: Layer $LAYER_DIGEST has unusual media type '$LAYER_MEDIA_TYPE', saving with .blob extension."
    fi
    LAYER_OUTPUT_PATH="$LAYERS_DIR/$LAYER_FILE_NAME"

    echo "Downloading layer $LAYER_DIGEST (Type: $LAYER_MEDIA_TYPE, Size: $LAYER_SIZE bytes) from: $LAYER_URL"
    HTTP_STATUS=$(make_request "$LAYER_URL" "$LAYER_OUTPUT_PATH" "application/octet-stream")
    MAKE_REQUEST_EXIT_STATUS=$?

    if [ "$MAKE_REQUEST_EXIT_STATUS" -ne 0 ]; then
        echo "Error: make_request function failed to download layer $LAYER_DIGEST. See errors above." >&2
        echo "Final reported HTTP status (if available): $HTTP_STATUS" >&2
        echo "Response headers (if available from last attempt):" >&2
        cat "$RESPONSE_HEADERS_FILE" >&2
        # Response body for layers is the layer file itself, which might be partially written or non-existent.
        # Avoid catting $LAYER_OUTPUT_PATH here as it could be huge or binary.
        echo "Layer download to $LAYER_OUTPUT_PATH may have failed or be incomplete." >&2
        rm -f "$RESPONSE_HEADERS_FILE" # Clean up before exiting
        # Decide if to continue or exit. Current behavior: exit on first layer failure.
        exit 1
    fi

    # If make_request succeeded (exit status 0), HTTP_STATUS should be 2xx.
    if [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ]; then
        echo "Error: Failed to download layer $LAYER_DIGEST. HTTP Status: $HTTP_STATUS" >&2
        echo "Response headers:" >&2
        cat "$RESPONSE_HEADERS_FILE" >&2
        # Avoid catting $LAYER_OUTPUT_PATH here.
        echo "Layer download to $LAYER_OUTPUT_PATH may have failed or be incomplete." >&2
        rm -f "$RESPONSE_HEADERS_FILE" # Clean up before exiting
        exit 1
    fi
    echo "Layer $LAYER_DIGEST saved to $LAYER_OUTPUT_PATH"
done

rm -f "$RESPONSE_HEADERS_FILE" # Clean up temp response headers file

echo "Image download process complete."
_SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
echo "All components (manifests, config, layers) are saved in: $(realpath "$OUTPUT_DIR")"

