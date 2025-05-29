# Download GitLab Docker Image Script

This PowerShell script (`Download-GitLabDockerImage.ps1`) allows you to download the components of a Docker image (manifest, configuration blob, and layers) directly from a GitLab Container Registry without using the `docker pull` command.

This is useful for:
- Inspecting individual image components.
- Downloading images in environments where Docker CLI is not available or restricted.
- Archiving image components.

**Note:** This script downloads the raw image components. It does *not* package them into a format directly loadable by `docker load`.

## Prerequisites

1.  **PowerShell**: The script is designed to run in a PowerShell environment.
2.  **GitLab Token**: You need a GitLab Personal Access Token (PAT), Deploy Token, or CI Job Token with at least the `read_registry` scope for the target GitLab instance and image repository.

## Usage

1.  Open a PowerShell terminal.
2.  Navigate to the directory containing the `Download-GitLabDockerImage.ps1` script.
3.  Execute the script with the required parameters.

### Parameters

*   `-RegistryUrl` (string, Mandatory): The Fully Qualified Domain Name (FQDN) of your GitLab Container Registry. 
    *   Example: `"registry.gitlab.com"`, `"gitlab.mycompany.com:5050"`
*   `-ImagePath` (string, Mandatory): The full path of the image within the registry, excluding the tag or registry URL.
    *   Example: `"mygroup/myproject/myimage"`, `"username/projectname/imagename"`
*   `-ImageTag` (string, Mandatory): The tag of the image you want to download.
    *   Example: `"latest"`, `"1.0.0"`, `"feature-branch"`
*   `-Token` (string, Mandatory): Your GitLab access token (PAT, Deploy Token, CI Job Token) with `read_registry` scope.
    *   If `-Username` is provided, this `Token` is used as the password for Basic Authentication.
    *   Otherwise, it's used as a Bearer token.
    *   Example: `"glpat-xxxxxxxxxxxxxxxxxxxx"`
*   `-Username` (string, Optional): The username for HTTP Basic Authentication.
    *   If provided, the script uses Basic Auth (`Username`:`Token`) instead of Bearer Token authentication.
    *   Common values:
        *   Your GitLab username (when using a Personal Access Token for `-Token`).
        *   The Deploy Token's username (when using a Deploy Token for `-Token`).
        *   `gitlab-ci-token` (when using a `CI_JOB_TOKEN` for `-Token`).
    *   Example: `"your_gitlab_username"`
*   `-OutputDirectory` (string, Optional): The local directory where the image components (manifests, config, layers) will be saved. 
    *   Defaults to `.\docker_image_download` (a subdirectory created in the current working directory).
    *   Example: `"C:\temp\my_downloaded_image"`, `"./downloaded_image_files"`

### Example Commands

**Using Bearer Token (default):**
```powershell
./Download-GitLabDockerImage.ps1 -RegistryUrl "registry.gitlab.com" -ImagePath "mygroup/myproject/myimage" -ImageTag "latest" -Token "YOUR_BEARER_TOKEN_HERE" -OutputDirectory "./my_image_components"
```

**Using Basic Authentication (with username and Personal Access Token as password):**
```powershell
./Download-GitLabDockerImage.ps1 -RegistryUrl "registry.gitlab.com" -ImagePath "mygroup/myproject/myimage" -ImageTag "latest" -Username "your_gitlab_username" -Token "YOUR_PERSONAL_ACCESS_TOKEN_HERE" -OutputDirectory "./my_image_components"
```

Replace the placeholder values with your specific details. The script will use the chosen authentication method.

## Output

The script will create the specified output directory (or `docker_image_download` by default) and save the following components:

*   **Manifest List (if applicable):** `manifest_list.json` (for multi-architecture images).
*   **Image Manifest:** `image_manifest.json` or `<digest>_manifest.json` (the specific manifest for the selected/default architecture).
*   **Image Configuration:** `<config_digest>.json`.
*   **Layers:** A subdirectory named `layers` containing all the image layer blobs (e.g., `<layer_digest>.tar.gz`).

## Troubleshooting

*   **401 Unauthorized:** 
    *   Ensure your token is correct and has not expired.
    *   Verify the token has the `read_registry` scope.
    *   For some self-managed GitLab instances, token authentication mechanisms might differ slightly. The script now supports both Bearer token and Basic Authentication (username/password).
*   **Manifest Fetch Issues:** The script attempts to fetch common manifest types. If you encounter issues with a specific registry or image, the manifest media type might be different or unexpected. The script saves unknown manifest types for debugging.
*   **Network Issues:** Ensure the machine running the script can reach the GitLab registry URL over HTTPS.

## Extract File From Docker Layer Script

This repository also includes `Extract-FileFromDockerLayer.ps1`, a PowerShell script designed to extract a specific file from a downloaded Docker image layer (which are typically `.tar` or `.tar.gz` archives).

This is useful for:
- Inspecting specific configuration files, binaries, or other assets within a layer without fully reconstructing the image.
- Retrieving individual files when you know which layer contains them.

### Prerequisites (for Extract-FileFromDockerLayer.ps1)

1.  **PowerShell**: Version 5.0 or later is recommended for `Expand-Archive` compatibility with `.tar.gz` files.
2.  **Downloaded Layer File**: You need a layer file, typically obtained using the `Download-GitLabDockerImage.ps1` script.

### Usage (Extract-FileFromDockerLayer.ps1)

1.  Open a PowerShell terminal.
2.  Navigate to the directory containing the `Extract-FileFromDockerLayer.ps1` script.
3.  Execute the script with the required parameters.

### Parameters (Extract-FileFromDockerLayer.ps1)

*   `-LayerFilePath` (string, Mandatory): The full path to the Docker image layer file.
    *   Example: `".\my_image_components\layers\sha256_abcdef12345.tar.gz"`
*   `-FileToExtractPathInLayer` (string, Mandatory): The relative path of the file *inside* the layer's archive.
    *   Example: `"app/config.ini"`, `"usr/local/bin/mytool"`
    *   **Note**: It's best to use relative paths without a leading slash. You might need to inspect the tarball's contents (e.g., using `tar -tvf <layer_file>`) to find the exact path.
*   `-OutputDirectory` (string, Mandatory): The directory where the extracted file will be saved. The script will attempt to create it if it doesn't exist.
    *   Example: `".\extracted_files"`
*   `-OutputFileName` (string, Optional): The name to give the extracted file. If not specified, the original filename from the archive is used.
    *   Example: `"my_specific_config.ini"`

### Example Command (Extract-FileFromDockerLayer.ps1)

```powershell
./Extract-FileFromDockerLayer.ps1 -LayerFilePath ".\my_image_components\layers\sha256_abcdef12345.tar.gz" -FileToExtractPathInLayer "app/settings.production.json" -OutputDirectory ".\configs_from_image" -OutputFileName "production_settings.json"
```

This command would:
1.  Look for the layer file at `.\my_image_components\layers\sha256_abcdef12345.tar.gz`.
2.  Attempt to find `app/settings.production.json` inside that layer.
3.  Save it as `production_settings.json` in the `.\configs_from_image` directory.

## Download GitLab Docker Image (Bash Script)

For users who prefer or require a Bash environment, `download_gitlab_docker_image.sh` provides similar functionality to the PowerShell download script. It uses `curl` for network requests and `jq` for parsing JSON responses.

### Prerequisites (for download_gitlab_docker_image.sh)

1.  **Bash**: A Bash-compatible shell.
2.  **`curl`**: The command-line tool for transferring data with URLs.
3.  **`jq`**: The command-line JSON processor.
4.  **Executable Permissions**: The script must be made executable (`chmod +x download_gitlab_docker_image.sh`).

You can typically install `curl` and `jq` using your system's package manager:
*   Debian/Ubuntu: `sudo apt update && sudo apt install -y curl jq`
*   Fedora: `sudo dnf install -y curl jq`
*   macOS (with Homebrew): `brew install curl jq`

### Usage (download_gitlab_docker_image.sh)

1.  Open a Bash terminal.
2.  Navigate to the directory containing the `download_gitlab_docker_image.sh` script.
3.  Ensure the script is executable: `chmod +x download_gitlab_docker_image.sh`.
4.  Execute the script with the required parameters.

### Parameters (download_gitlab_docker_image.sh)

*   `-r <registry_url>`: (Mandatory) FQDN of the GitLab Container Registry (e.g., `registry.gitlab.com`).
*   `-i <image_path>`: (Mandatory) Full path of the image (e.g., `mygroup/myproject/myimage`).
*   `-t <image_tag>`: (Mandatory) Tag of the image (e.g., `latest`, `1.0.0`).
*   `-k <token>`: (Mandatory) GitLab Token (PAT, Deploy Token, CI Job Token) with `read_registry` scope. Used as the password if `-U` is provided, otherwise as a Bearer token.
*   `-U <username>`: (Optional) Username for HTTP Basic Authentication. If provided, the script uses Basic Auth (`username:token`). Common values:
    *   Your GitLab username (when using a Personal Access Token for `-k`).
    *   The Deploy Token's username (when using a Deploy Token for `-k`).
    *   `gitlab-ci-token` (when using a `CI_JOB_TOKEN` for `-k`).
*   `-o <output_directory>`: (Optional) Directory to save image components. Defaults to `./docker_image_download`.

### Example Commands (download_gitlab_docker_image.sh)

**Using Bearer Token (default):**
```bash
./download_gitlab_docker_image.sh \\
    -r "registry.gitlab.com" \\
    -i "mygroup/myproject/myimage" \\
    -t "latest" \\
    -k "YOUR_BEARER_TOKEN_HERE" \\
    -o "./my_image_components_bash"
```

**Using Basic Authentication (with username and Personal Access Token as password):**
```bash
./download_gitlab_docker_image.sh \\
    -r "registry.gitlab.com" \\
    -i "mygroup/myproject/myimage" \\
    -t "latest" \\
    -U "your_gitlab_username" \\
    -k "YOUR_PERSONAL_ACCESS_TOKEN_HERE" \\
    -o "./my_image_components_bash"
```

These commands will download the components of the specified image into the `./my_image_components_bash` directory using the chosen authentication method.
