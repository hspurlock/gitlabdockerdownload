#!/bin/bash

# Script to upload a file as a generic package to GitLab
# Supports JWT authentication with fallback to direct Bearer token

set -eo pipefail

# --- Configuration & Globals ---
GITLAB_URL=""
PROJECT_ID_OR_PATH=""
PACKAGE_NAME=""
PACKAGE_VERSION=""
FILE_TO_UPLOAD=""
USER_TOKEN=""
USERNAME=""
AUTH_REALM=""
AUTH_SERVICE=""
REQUESTED_JWT_SCOPE="api" # Default scope for generic packages API
DEBUG_MODE="false"

# Internal JWT state
TOKEN_REALM=""
TOKEN_SERVICE=""
CURRENT_JWT=""

# --- Helper Functions ---

echo_error() {
    echo "[ERROR] $1" >&2
}

echo_warn() {
    echo "[WARN] $1" >&2
}

echo_info() {
    echo "[INFO] $1" >&2
}

usage() {
    echo "Usage: $0 -g <gitlab_url> -p <project_id_or_path> -n <package_name> -v <package_version> -f <file_to_upload> -k <token> [-U <username>] [-A <auth_realm>] [-S <auth_service>] [--scope <jwt_scope>] [-D]"
    echo ""
    echo "Parameters:"
    echo "  -g <gitlab_url>          : GitLab instance URL (e.g., gitlab.com, gitlab.mycompany.com)"
    echo "  -p <project_id_or_path>  : Project ID or URL-encoded path (e.g., 12345 or mygroup/myproject)"
    echo "  -n <package_name>        : Name of the generic package"
    echo "  -v <package_version>     : Version of the generic package"
    echo "  -f <file_to_upload>      : Path to the local file to upload"
    echo "  -k <token>               : GitLab Token (PAT, Deploy Token, CI Job Token)"
    echo "  -U <username>            : (Optional) Username for Basic Auth to JWT endpoint"
    echo "  -A <auth_realm>          : (Optional) JWT authentication realm URL. Overrides discovery."
    echo "  -S <auth_service>        : (Optional) JWT authentication service name. Overrides discovery."
    echo "  --scope <jwt_scope>      : (Optional) Scope for JWT request. Defaults to 'api'."
    echo "  -D                       : (Optional) Enable debug mode (prints more verbose output)."
    echo ""
    echo "Example:"
    echo "  $0 -g gitlab.com -p mygroup/myproject -n mypackage -v 1.0.0 -f ./artifact.zip -k YOUR_GITLAB_TOKEN"
    exit 1
}

# --- Argument Parsing ---
while getopts ":g:p:n:v:f:k:U:A:S:D-:" opt; do
    case ${opt} in
        g) GITLAB_URL=$OPTARG ;; 
        p) PROJECT_ID_OR_PATH=$OPTARG ;; 
        n) PACKAGE_NAME=$OPTARG ;; 
        v) PACKAGE_VERSION=$OPTARG ;; 
        f) FILE_TO_UPLOAD=$OPTARG ;; 
        k) USER_TOKEN=$OPTARG ;; 
        U) USERNAME=$OPTARG ;; 
        A) AUTH_REALM=$OPTARG ;; 
        S) AUTH_SERVICE=$OPTARG ;; 
        D) DEBUG_MODE="true" ;; 
        -) 
            case "${OPTARG}" in
                scope) REQUESTED_JWT_SCOPE="${!OPTIND}"; OPTIND=$((OPTIND + 1)) ;;
                *) if [ "$OPTERR" = 1 ] && [ "${optspec:0:1}" != ":" ]; then echo "Invalid option --$OPTARG" >&2; usage; fi ;;
            esac ;;
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
shift $((OPTIND -1))

# Validate mandatory parameters
if [ -z "$GITLAB_URL" ] || [ -z "$PROJECT_ID_OR_PATH" ] || [ -z "$PACKAGE_NAME" ] || [ -z "$PACKAGE_VERSION" ] || [ -z "$FILE_TO_UPLOAD" ] || [ -z "$USER_TOKEN" ]; then
    echo_error "Missing one or more mandatory parameters."
    usage
fi

if [ ! -f "$FILE_TO_UPLOAD" ]; then
    echo_error "File to upload not found: $FILE_TO_UPLOAD"
    exit 1
fi

# Ensure jq is installed for URL encoding
if ! command -v jq &> /dev/null; then
    echo_error "jq is not installed. Please install jq to use this script."
    exit 1
fi

# Normalize GitLab URL: remove scheme, remove trailing slashes, then add https://
GITLAB_URL_NO_SCHEME=$(echo "$GITLAB_URL" | sed -e 's|^[^/]*//||' -e 's:/*$::')
GITLAB_URL_BASE="https://$GITLAB_URL_NO_SCHEME"

# URL Encode components
PROJECT_IDENTIFIER_ENCODED=$(echo "$PROJECT_ID_OR_PATH" | jq -sRr @uri)
PACKAGE_NAME_ENCODED=$(echo "$PACKAGE_NAME" | jq -sRr @uri)
PACKAGE_VERSION_ENCODED=$(echo "$PACKAGE_VERSION" | jq -sRr @uri)
UPLOAD_FILE_BASENAME=$(basename "$FILE_TO_UPLOAD")
UPLOAD_FILE_BASENAME_ENCODED=$(echo "$UPLOAD_FILE_BASENAME" | jq -sRr @uri)

if [ "$DEBUG_MODE" = "true" ]; then
    echo_info "[DEBUG] GITLAB_URL_BASE: $GITLAB_URL_BASE"
    echo_info "[DEBUG] PROJECT_IDENTIFIER_ENCODED: $PROJECT_IDENTIFIER_ENCODED"
    echo_info "[DEBUG] PACKAGE_NAME_ENCODED: $PACKAGE_NAME_ENCODED"
    echo_info "[DEBUG] PACKAGE_VERSION_ENCODED: $PACKAGE_VERSION_ENCODED"
    echo_info "[DEBUG] UPLOAD_FILE_BASENAME_ENCODED: $UPLOAD_FILE_BASENAME_ENCODED"
fi

# --- JWT Authentication Functions (to be adapted) ---

# discover_auth_params function (adapted for generic packages API)
# Tries to discover TOKEN_REALM and TOKEN_SERVICE from GitLab API
# Params:
#   $1: GitLab Base URL (e.g., gitlab.com)
#   $2: URL-encoded Project Identifier
#   $3: User Token (for initial authenticated probe if needed)
#   $4: Username (for initial authenticated probe if needed)
discover_auth_params() {
    local base_url=$1
    local project_id_enc=$2
    local current_token=$3
    local current_username=$4

    # Probe the base packages API for the project
    # $base_url should now already have https://
    local discovery_api_url="$base_url/api/v4/projects/$project_id_enc/packages"
    echo_info "Attempting to discover authentication parameters from $discovery_api_url"

    local auth_header=""
    if [ -n "$current_username" ]; then
        local basic_auth
        basic_auth=$(echo -n "$current_username:$current_token" | base64)
        auth_header="Authorization: Basic $basic_auth"
    elif [ -n "$current_token" ]; then
        auth_header="Authorization: Bearer $current_token"
    fi

    # Use a HEAD request to minimize data transfer, expect 401
    local www_authenticate_header
    www_authenticate_header=$(curl --silent --show-error --location --request HEAD \
        ${auth_header:+-H "$auth_header"} \
        --dump-header - \
        "$discovery_api_url" | grep -i '^Www-Authenticate:') || true # Continue if grep fails (no header)

    if [ -n "$www_authenticate_header" ]; then
        echo_info "Www-Authenticate header found: $www_authenticate_header"
        # Format: Bearer realm="<realm_url>",service="<service_name>",error="<error>",scope="<scope>"
        # We only care about realm and service for now.
        TOKEN_REALM=$(echo "$www_authenticate_header" | grep -oP 'realm="\K[^"]*')
        TOKEN_SERVICE=$(echo "$www_authenticate_header" | grep -oP 'service="\K[^"]*')

        if [ -n "$TOKEN_REALM" ]; then
            echo_info "Discovered Realm: $TOKEN_REALM"
        else
            echo_warn "Could not parse realm from Www-Authenticate header."
        fi
        if [ -n "$TOKEN_SERVICE" ]; then
            echo_info "Discovered Service: $TOKEN_SERVICE"
        else
            # Default service if not found in header but realm is present (common for Docker registry context)
            # For generic API, service might be more critical or different. Let's not default yet.
            echo_warn "Could not parse service from Www-Authenticate header."
        fi
    else
        echo_info "No Www-Authenticate header found from $discovery_api_url. JWT auto-discovery might not be supported or needed for this endpoint."
    fi
}

# fetch_registry_jwt function (adapted)
# Fetches a JWT using the discovered/provided realm, service, and scope
# Params:
#   $1: Token Realm URL
#   $2: Token Service Name
#   $3: Requested Scope (e.g., "api", "repository:mygroup/myproject:pull,push")
#   $4: Username for JWT endpoint auth
#   $5: User Token for JWT endpoint auth
fetch_registry_jwt() {
    local realm_url=$1
    local service_name=$2
    local scope_to_request=$3
    local jwt_auth_user=$4
    local jwt_auth_token=$5

    if [ -z "$realm_url" ]; then
        echo_error "Token Realm is not set. Cannot fetch JWT."
        return 1
    fi
    # Service name might be optional for some realms or implicitly part of the realm URL structure.
    # The standard Docker token auth requires it.
    if [ -z "$service_name" ]; then
        echo_warn "Token Service is not set. Proceeding, but JWT request might fail."
    fi

    local token_req_url="$realm_url?service=$service_name&scope=$scope_to_request"
    # Some GitLab versions might also need: &client_id=docker
    # token_req_url+="&client_id=docker" 

    echo_info "Requesting JWT from $token_req_url (Scope: $scope_to_request)"

    local auth_header_val=""
    if [ -n "$jwt_auth_user" ]; then
        local basic_auth_jwt
        basic_auth_jwt=$(echo -n "$jwt_auth_user:$jwt_auth_token" | base64)
        auth_header_val="Authorization: Basic $basic_auth_jwt"
    else
        auth_header_val="Authorization: Bearer $jwt_auth_token"
    fi

    local response
    response=$(curl --silent --show-error --location -G \
        -H "$auth_header_val" \
        -H "Content-Type: application/json" \
        "$token_req_url")

    # Response is typically JSON: {"token": "..."} or {"access_token": "..."}
    CURRENT_JWT=$(echo "$response" | jq -r '.token // .access_token // empty')

    if [ -z "$CURRENT_JWT" ]; then
        echo_error "Failed to obtain JWT. Response: $response"
        return 1
    else
        echo_info "Successfully obtained JWT."
    fi
    return 0
}

# --- Main Upload Logic ---
echo_info "Starting GitLab Generic Package Upload..."

# Step 1: Determine Authentication Method
AUTH_HEADER_FOR_UPLOAD=""
USE_DIRECT_TOKEN_AUTH=false

if [ -z "$AUTH_REALM" ] || [ -z "$AUTH_SERVICE" ]; then # If realm or service not manually provided, try discovery
    echo_info "Auth Realm or Service not provided, attempting discovery..."
    discover_auth_params "$GITLAB_URL_BASE" "$PROJECT_IDENTIFIER_ENCODED" "$USER_TOKEN" "$USERNAME"
    if [ -z "$TOKEN_REALM" ]; then # Check if discovery set the global TOKEN_REALM
        echo_warn "JWT Realm discovery failed or not supported by endpoint. Will attempt to use token directly."
        USE_DIRECT_TOKEN_AUTH=true
    else
        # Use discovered realm/service. If user provided one, it will override discovered one later.
        AUTH_REALM=${AUTH_REALM:-$TOKEN_REALM} 
        AUTH_SERVICE=${AUTH_SERVICE:-$TOKEN_SERVICE}
    fi
else
    echo_info "Using manually provided Auth Realm and Service."
fi

if [ "$USE_DIRECT_TOKEN_AUTH" = false ]; then
    if [ -z "$AUTH_REALM" ]; then # Final check if realm is available for JWT path
        echo_error "JWT Authentication selected/defaulted, but Auth Realm is missing and not discovered."
        exit 1
    fi
    echo_info "Attempting to fetch JWT using Realm: $AUTH_REALM, Service: $AUTH_SERVICE, Scope: $REQUESTED_JWT_SCOPE"
    if ! fetch_registry_jwt "$AUTH_REALM" "$AUTH_SERVICE" "$REQUESTED_JWT_SCOPE" "$USERNAME" "$USER_TOKEN"; then
        echo_error "Failed to obtain initial JWT. Exiting."
        exit 1
    fi
    AUTH_HEADER_FOR_UPLOAD="Authorization: Bearer $CURRENT_JWT"
else
    echo_info "Using direct token authentication (Bearer)."
    AUTH_HEADER_FOR_UPLOAD="Authorization: Bearer $USER_TOKEN"
fi

# Step 2: Construct Upload URL
UPLOAD_URL="$GITLAB_URL_BASE/api/v4/projects/$PROJECT_IDENTIFIER_ENCODED/packages/generic/$PACKAGE_NAME_ENCODED/$PACKAGE_VERSION_ENCODED/$UPLOAD_FILE_BASENAME_ENCODED"
if [ "$DEBUG_MODE" = "true" ]; then
    echo_info "[DEBUG] Final UPLOAD_URL: $UPLOAD_URL"
else
    echo_info "Upload URL: $UPLOAD_URL"
fi

# Step 3: Perform Upload (with potential retry for JWT)
ATTEMPT=1
MAX_ATTEMPTS=2
UPLOAD_SUCCESSFUL=false

while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    echo_info "Attempting upload (Attempt $ATTEMPT/$MAX_ATTEMPTS)..."
    HTTP_STATUS=$(curl --silent --show-error --location --request PUT \
        --header "$AUTH_HEADER_FOR_UPLOAD" \
        --upload-file "$FILE_TO_UPLOAD" \
        --write-out "%{http_code}" \
        --output /dev/null \
        "$UPLOAD_URL")

    echo_info "Upload attempt $ATTEMPT finished with HTTP status: $HTTP_STATUS"

    if [ "$HTTP_STATUS" -eq 200 ] || [ "$HTTP_STATUS" -eq 201 ]; then
        echo_info "File uploaded successfully!"
        UPLOAD_SUCCESSFUL=true
        break
    elif [ "$HTTP_STATUS" -eq 401 ] && [ "$USE_DIRECT_TOKEN_AUTH" = false ] && [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
        echo_warn "Received 401 (Unauthorized). Attempting to refresh JWT and retry..."
        CURRENT_JWT="" # Clear old JWT
        if ! fetch_registry_jwt "$AUTH_REALM" "$AUTH_SERVICE" "$REQUESTED_JWT_SCOPE" "$USERNAME" "$USER_TOKEN"; then
            echo_error "Failed to refresh JWT. Cannot retry upload."
            break
        fi
        AUTH_HEADER_FOR_UPLOAD="Authorization: Bearer $CURRENT_JWT"
    else
        echo_error "Upload failed with HTTP status: $HTTP_STATUS. For details, run curl with -v."
        # Consider showing response body if not too large, or if output was not /dev/null
        # Example: curl -v ... "$UPLOAD_URL" (without --output /dev/null and --silent for debugging)
        break
    fi
    ATTEMPT=$((ATTEMPT + 1))
done

if [ "$UPLOAD_SUCCESSFUL" = true ]; then
    echo_info "Upload process complete."
    exit 0
else
    echo_error "Upload process failed."
    exit 1
fi
