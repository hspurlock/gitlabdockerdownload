#!/bin/bash

# Script to download a Docker image (manifest, config, layers) from a GitLab Container Registry.
# Requires curl and jq.

set -e # Exit immediately if a command exits with a non-zero status.
# set -x # Debug mode

usage() {
    echo "Usage: $0 -r <registry_url> -i <image_path> -t <image_tag> -k <token> [-U <username>] [-o <output_directory>]"
    echo "  -r REGISTRY_URL:      FQDN of the GitLab Container Registry (e.g., registry.gitlab.com)"
    echo "  -i IMAGE_PATH:        Full path of the image (e.g., mygroup/myproject/myimage)"
    echo "  -t IMAGE_TAG:         Tag of the image (e.g., latest, 1.0.0)"
    echo "  -k TOKEN:             GitLab Token (PAT, Deploy Token, CI Job Token) with read_registry scope"
    echo "  -U USERNAME:          Optional. Username for Basic Authentication (e.g., your GitLab username for PAT, 'gitlab-ci-token' for CI job token, or Deploy Token username). If provided, TOKEN is used as the password."
    echo "  -o OUTPUT_DIRECTORY:  Optional. Directory to save image components (default: ./docker_image_download)"
    exit 1
}

OUTPUT_DIR="./docker_image_download"
USERNAME=""

while getopts ":r:i:t:k:U:o:" opt; do
    case ${opt} in
        r) REGISTRY_URL=$OPTARG ;; 
        i) IMAGE_PATH=$OPTARG ;;  
        t) IMAGE_TAG=$OPTARG ;;   
        k) TOKEN=$OPTARG ;;       
        U) USERNAME=$OPTARG ;;   
        o) OUTPUT_DIR=$OPTARG ;;  
        \?) echo "Invalid option: $OPTARG" 1>&2; usage ;; 
        :) echo "Invalid option: $OPTARG requires an argument" 1>&2; usage ;; 
    esac
done

if [ -z "$REGISTRY_URL" ] || [ -z "$IMAGE_PATH" ] || [ -z "$IMAGE_TAG" ] || [ -z "$TOKEN" ]; then
    echo "Error: Missing mandatory arguments."
    usage
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
RESPONSE_HEADERS_FILE=$(mktemp)

make_request() {
    local url="$1"
    local output_file="$2"
    local extra_accept_header="$3"

    local accept_header="application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json"
    if [ -n "$extra_accept_header" ]; then
        accept_header="$extra_accept_header"
    fi

    local auth_opts
    if [ -n "$USERNAME" ]; then
        auth_opts=(-u "$USERNAME:$TOKEN")
    else
        auth_opts=(-H "Authorization: Bearer $TOKEN")
    fi

    if [ -n "$output_file" ]; then
        http_status=$(curl -sSL -w "%{http_code}" \
            "${auth_opts[@]}" \
            -H "Accept: $accept_header" \
            -D "$RESPONSE_HEADERS_FILE" \
            -o "$output_file" \
            "$url")
        echo "$http_status"
    else
        # If no output file, curl outputs to stdout, so we can't also output http_status easily to stdout.
        # Instead, capture stdout to a variable, and http_status separately.
        response_body_and_status=$(curl -sSL -w "\n%{http_code}" \
            "${auth_opts[@]}" \
            -H "Accept: $accept_header" \
            -D "$RESPONSE_HEADERS_FILE" \
            "$url")
        response_body=$(echo "$response_body_and_status" | sed '$d') # all but last line
        http_status=$(echo "$response_body_and_status" | tail -n1)   # last line
        echo "$response_body"
        return "$http_status" # This doesn't quite work as intended for returning status code with body.
                               # For simplicity, when no output_file, assume success or handle error based on jq parsing.
    fi
}

# 1. Fetch the manifest
MANIFEST_URL="https://$REGISTRY_URL/v2/$IMAGE_PATH/manifests/$IMAGE_TAG"
echo "Fetching manifest from: $MANIFEST_URL"

MANIFEST_FILE_TMP="$OUTPUT_DIR/manifest_initial_response.json"
HTTP_STATUS=$(make_request "$MANIFEST_URL" "$MANIFEST_FILE_TMP")

if [ "$HTTP_STATUS" -ne 200 ]; then
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
    
    if [ "$HTTP_STATUS" -ne 200 ]; then
        echo "Error: Failed to fetch specific architecture manifest $SELECTED_MANIFEST_DIGEST. HTTP Status: $HTTP_STATUS" >&2
        cat "$RESPONSE_HEADERS_FILE" >&2
        cat "$ACTUAL_MANIFEST_CONTENT_FILE" >&2
        rm -f "$RESPONSE_HEADERS_FILE"
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

if [ "$HTTP_STATUS" -ne 200 ]; then
    echo "Error: Failed to download image config blob $CONFIG_DIGEST. HTTP Status: $HTTP_STATUS" >&2
    cat "$RESPONSE_HEADERS_FILE" >&2
    cat "$CONFIG_OUTPUT_PATH" >&2 # This might be binary or partial if download failed
    rm -f "$RESPONSE_HEADERS_FILE"
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

    if [ "$HTTP_STATUS" -ne 200 ]; then
        echo "Error: Failed to download layer $LAYER_DIGEST. HTTP Status: $HTTP_STATUS" >&2
        cat "$RESPONSE_HEADERS_FILE" >&2
        # cat "$LAYER_OUTPUT_PATH" # Potentially large and binary
        # Decide if to continue or exit. Exiting on first layer failure.
        rm -f "$RESPONSE_HEADERS_FILE"
        exit 1
    fi
    echo "Layer $LAYER_DIGEST saved to $LAYER_OUTPUT_PATH"
done

rm -f "$RESPONSE_HEADERS_FILE" # Clean up temp response headers file

echo "Image download process complete."
_SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
echo "All components (manifests, config, layers) are saved in: $(realpath "$OUTPUT_DIR")"

