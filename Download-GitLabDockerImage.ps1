<#
.SYNOPSIS
    Downloads a Docker image (manifest, config, layers) from a GitLab Container Registry without using 'docker pull'.

.DESCRIPTION
    This script connects to a GitLab Container Registry using a provided token,
    fetches the image manifest, and then downloads the image configuration blob
    and all associated layers. It saves these components to a specified output directory.

    This script does NOT package the downloaded components into a 'docker load' compatible tarball.
    It only downloads the raw components.

.PARAMETER RegistryUrl
    The FQDN of the GitLab Container Registry.
    Example: "registry.gitlab.com" or "gitlab.mycompany.com:5050"

.PARAMETER ImagePath
    The full path of the image in the registry, without the tag or registry URL.
    Example: "mygroup/myproject/myimage" or "username/projectname/imagename"

.PARAMETER ImageTag
    The tag of the image to download.
    Example: "latest", "1.0.0"

.PARAMETER Token
    A GitLab Personal Access Token (PAT), Deploy Token, or CI Job Token with at least 'read_registry' scope.
    This token will be used in an Authorization Bearer header.

.PARAMETER OutputDirectory
    Optional. The directory where the image components will be saved.
    Defaults to ".\docker_image_download".

.EXAMPLE
    .\Download-GitLabDockerImage.ps1 -RegistryUrl "registry.gitlab.com" -ImagePath "myusername/myproject/myimage" -ImageTag "latest" -Token "your_gitlab_token_here" -OutputDirectory "C:\temp\my_downloaded_image"

    This command downloads the 'latest' tag of 'myusername/myproject/myimage' from 'registry.gitlab.com'
    using the provided token and saves the components to "C:\temp\my_downloaded_image".
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$RegistryUrl, 

    [Parameter(Mandatory=$true)]
    [string]$ImagePath,   

    [Parameter(Mandatory=$true)]
    [string]$ImageTag,    

    [Parameter(Mandatory=$true)]
    [string]$Token,       

    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory = ".\docker_image_download"
)

$ErrorActionPreference = "Stop" # Stop on errors

# Ensure output directory exists
if (-not (Test-Path $OutputDirectory)) {
    Write-Host "Creating output directory: $OutputDirectory"
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}
Write-Host "Image components will be saved to: $(Resolve-Path $OutputDirectory)"

# Construct Headers for registry communication
$headers = @{
    "Authorization" = "Bearer $Token"
}

# 1. Fetch the manifest
# The manifest URL typically looks like: https://<registry_url>/v2/<image_name>/manifests/<tag_or_digest>
$manifestUrl = "https://$($RegistryUrl)/v2/$($ImagePath)/manifests/$($ImageTag)"
Write-Host "Fetching manifest from: $manifestUrl"

# Request multiple manifest types. The registry will return the most specific one it supports.
$manifestHeaders = $headers.Clone() # Clone base headers
$manifestHeaders.Add("Accept", "application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json")

$manifestResponse = $null
try {
    $manifestResponse = Invoke-RestMethod -Uri $manifestUrl -Headers $manifestHeaders -Method Get -ContentType "application/json"
} catch {
    $statusCode = "Unknown"
    $responseContent = "No response content"
    if ($_.Exception.Response) {
        $statusCode = $_.Exception.Response.StatusCode
        $responseContent = $_.Exception.Response.Content
    }
    Write-Error "Failed to fetch manifest. Status: $statusCode | Response: $responseContent"
    if ($statusCode -eq 401) {
        Write-Warning "Received 401 (Unauthorized). Ensure your token is correct, has 'read_registry' scope, and is not expired."
        Write-Warning "For some GitLab setups, you might need to authenticate against a different endpoint first to get a registry-specific JWT, but this script assumes direct token use."
    }
    exit 1
}

$manifestMediaType = $manifestResponse.PSObject.Properties['mediaType'].Value # Robust way to get property
Write-Host "Initial manifest media type: $manifestMediaType"

$actualManifest = $null       # This will hold the image manifest (single architecture)
$selectedManifestDigest = $null # To store digest if fetched from a list

if ($manifestMediaType -eq "application/vnd.docker.distribution.manifest.list.v2+json" -or $manifestMediaType -eq "application/vnd.oci.image.index.v1+json") {
    Write-Host "Detected a manifest list (multi-architecture image)."
    # Save the manifest list itself
    $manifestListFilePath = Join-Path $OutputDirectory "manifest_list.json"
    $manifestResponse | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestListFilePath
    Write-Host "Manifest list saved to $manifestListFilePath"

    # Attempt to find a manifest for amd64/linux, a common default.
    $targetPlatform = @{ architecture = "amd64"; os = "linux" }

    foreach ($m in $manifestResponse.manifests) {
        if ($m.platform.architecture -eq $targetPlatform.architecture -and $m.platform.os -eq $targetPlatform.os) {
            $selectedManifestDigest = $m.digest
            Write-Host "Found manifest for $($targetPlatform.architecture)/$($targetPlatform.os): $selectedManifestDigest"
            break
        }
    }

    if (-not $selectedManifestDigest) {
        Write-Warning "Could not find a manifest for $($targetPlatform.architecture)/$($targetPlatform.os)."
        if ($manifestResponse.manifests -and $manifestResponse.manifests.Count -gt 0) {
            $selectedManifestDigest = $manifestResponse.manifests[0].digest
            $selectedPlatformInfo = "$($manifestResponse.manifests[0].platform.os)/$($manifestResponse.manifests[0].platform.architecture)"
            Write-Host "Using the first available manifest in the list: $selectedManifestDigest (Platform: $selectedPlatformInfo)"
        } else {
            Write-Error "Manifest list is empty or malformed."
            exit 1
        }
    }

    # Fetch the selected architecture-specific manifest
    $specificManifestUrl = "https://$($RegistryUrl)/v2/$($ImagePath)/manifests/$($selectedManifestDigest)"
    $specificManifestHeaders = $headers.Clone()
    # Request specific manifest types for single architecture images
    $specificManifestHeaders.Add("Accept", "application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json")
    
    Write-Host "Fetching specific architecture manifest ($selectedManifestDigest) from: $specificManifestUrl"
    try {
        $actualManifest = Invoke-RestMethod -Uri $specificManifestUrl -Headers $specificManifestHeaders -Method Get -ContentType "application/json"
    } catch {
        $statusCode = "Unknown"
        $responseContent = "No response content"
        if ($_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode
            $responseContent = $_.Exception.Response.Content
        }
        Write-Error "Failed to fetch specific architecture manifest $selectedManifestDigest. Status: $statusCode | Response: $responseContent"
        exit 1
    }

} elseif ($manifestMediaType -eq "application/vnd.docker.distribution.manifest.v2+json" -or $manifestMediaType -eq "application/vnd.oci.image.manifest.v1+json") {
    Write-Host "Detected a single architecture image manifest."
    $actualManifest = $manifestResponse
} else {
    Write-Error "Unsupported manifest media type: $manifestMediaType"
    # Save the problematic manifest for debugging
    $unknownManifestFilePath = Join-Path $OutputDirectory "unknown_manifest_type.json"
    $manifestResponse | ConvertTo-Json -Depth 10 | Set-Content -Path $unknownManifestFilePath
    Write-Host "Unknown manifest content saved to $unknownManifestFilePath for debugging."
    exit 1
}

if (-not $actualManifest) {
    Write-Error "Could not determine the actual image manifest to process after initial fetch."
    exit 1
}

# Save the final working manifest (either single arch or selected from list)
$manifestFileName = "image_manifest.json"
if ($selectedManifestDigest) { # If it was from a list, use its digest in the filename for clarity
    $manifestFileName = "$($selectedManifestDigest -replace ':', '_')_manifest.json"
}
$manifestFilePath = Join-Path $OutputDirectory $manifestFileName
$actualManifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFilePath
Write-Host "Final image manifest saved to $manifestFilePath"

# Extract config and layers info from the chosen manifest
$imageConfigDescriptor = $actualManifest.config
$layerDescriptors = $actualManifest.layers

# 2. Download the image configuration blob
$configDigest = $imageConfigDescriptor.digest
$configUrl = "https://$($RegistryUrl)/v2/$($ImagePath)/blobs/$($configDigest)"
# OCI spec implies config is JSON. Docker v2 schema also typically JSON.
$configFileName = "$($configDigest -replace ':', '_').json"
$configOutputPath = Join-Path $OutputDirectory $configFileName

Write-Host "Downloading image config ($configDigest) from: $configUrl"
try {
    # Using Invoke-WebRequest for potentially better handling of binary/JSON downloads to file
    Invoke-WebRequest -Uri $configUrl -Headers $headers -Method Get -OutFile $configOutputPath
    Write-Host "Image config saved to $configOutputPath"
} catch {
    $statusCode = "Unknown"
    $responseContent = "No response content"
    if ($_.Exception.Response) {
        $statusCode = $_.Exception.Response.StatusCode
        $responseContent = $_.Exception.Response.Content
    }
    Write-Error "Failed to download image config blob $configDigest. Status: $statusCode | Response: $responseContent"
    exit 1
}

# 3. Download layers
$layersDir = Join-Path $OutputDirectory "layers"
if (-not (Test-Path $layersDir)) {
    New-Item -ItemType Directory -Path $layersDir -Force | Out-Null
}

Write-Host "Downloading $(($layerDescriptors).Count) layers to: $layersDir"
foreach ($layer in $layerDescriptors) {
    $layerDigest = $layer.digest
    $layerMediaType = $layer.mediaType
    $layerUrl = "https://$($RegistryUrl)/v2/$($ImagePath)/blobs/$($layerDigest)"
    
    # Determine file extension based on media type
    $layerFileName = "$($layerDigest -replace ':', '_')"
    if ($layerMediaType -like "*tar+gzip*" -or $layerMediaType -like "*tar.gzip*") {
        $layerFileName += ".tar.gz"
    } elseif ($layerMediaType -like "*tar*") {
        $layerFileName += ".tar"
    } else {
        $layerFileName += ".blob" # Generic extension for unknown types
        Write-Warning "Layer $layerDigest has media type '$layerMediaType', saving with .blob extension."
    }
    $layerOutputPath = Join-Path $layersDir $layerFileName
    
    Write-Host "Downloading layer $layerDigest (Type: $layerMediaType, Size: $($layer.size) bytes) from: $layerUrl"
    try {
        Invoke-WebRequest -Uri $layerUrl -Headers $headers -Method Get -OutFile $layerOutputPath
        Write-Host "Layer $layerDigest saved to $layerOutputPath"
    } catch {
        $statusCode = "Unknown"
        $responseContent = "No response content"
        if ($_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode
            $responseContent = $_.Exception.Response.Content
        }
        Write-Error "Failed to download layer $layerDigest. Status: $statusCode | Response: $responseContent"
        # If a layer fails, the image is incomplete. Decide if to continue or exit.
        exit 1 # Exiting on first layer failure for simplicity
    }
}

Write-Host "Image download process complete."
Write-Host "All components (manifests, config, layers) are saved in: $(Resolve-Path $OutputDirectory)"
Write-Host "Note: These are raw components. To use with 'docker load', they would need to be packaged into a specific tarball format."
