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
*   `-Token` (string, Mandatory): Your GitLab access token with `read_registry` scope.
    *   Example: `"glpat-xxxxxxxxxxxxxxxxxxxx"`
*   `-OutputDirectory` (string, Optional): The local directory where the image components (manifests, config, layers) will be saved. 
    *   Defaults to `.\docker_image_download` (a subdirectory created in the current working directory).
    *   Example: `"C:\temp\my_downloaded_image"`, `"./downloaded_image_files"`

### Example Command

```powershell
./Download-GitLabDockerImage.ps1 -RegistryUrl "registry.gitlab.com" -ImagePath "mygroup/myproject/myimage" -ImageTag "latest" -Token "YOUR_GITLAB_TOKEN_HERE" -OutputDirectory "./my_image_components"
```

Replace `"registry.gitlab.com"`, `"mygroup/myproject/myimage"`, `"latest"`, and `"YOUR_GITLAB_TOKEN_HERE"` with your specific details.

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
    *   For some self-managed GitLab instances, token authentication mechanisms might differ slightly. This script uses standard Bearer token authentication.
*   **Manifest Fetch Issues:** The script attempts to fetch common manifest types. If you encounter issues with a specific registry or image, the manifest media type might be different or unexpected. The script saves unknown manifest types for debugging.
*   **Network Issues:** Ensure the machine running the script can reach the GitLab registry URL over HTTPS.
