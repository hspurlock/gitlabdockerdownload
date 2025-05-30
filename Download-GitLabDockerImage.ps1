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
    If -Username is provided, this Token is used as the password for Basic Authentication.
    Otherwise, it's used as a Bearer token.

.PARAMETER Username
    Optional. The username for HTTP Basic Authentication. 
    If provided, the script uses Basic Auth (username:Token) instead of Bearer Token authentication.
    Common values:
    - Your GitLab username (when using a Personal Access Token for -Token).
    - The Deploy Token's username (when using a Deploy Token for -Token).
    - `gitlab-ci-token` (when using a CI_JOB_TOKEN for -Token).

.PARAMETER OutputDirectory
    Optional. The directory where the image components will be saved.
    Defaults to ".\docker_image_download".

.PARAMETER AuthRealm
    Optional. The URL of the token authentication server (realm). 
    If not provided, the script will attempt to discover it.

.PARAMETER AuthService
    Optional. The service name for token authentication.
    If not provided, the script will attempt to discover it (or use a default).

.EXAMPLE
    # Example 1: Using Bearer Token (default)
    .\Download-GitLabDockerImage.ps1 -RegistryUrl "registry.gitlab.com" -ImagePath "myusername/myproject/myimage" -ImageTag "latest" -Token "YOUR_BEARER_TOKEN_HERE"

    # Example 2: Using Basic Authentication with a Personal Access Token
    .\Download-GitLabDockerImage.ps1 -RegistryUrl "registry.gitlab.com" -ImagePath "myusername/myproject/myimage" -ImageTag "latest" -Username "your_gitlab_username" -Token "YOUR_PERSONAL_ACCESS_TOKEN_HERE" -OutputDirectory "C:\temp\my_image"

    These commands download the 'latest' tag of 'myusername/myproject/myimage' from 'registry.gitlab.com'
    using the specified authentication method and save the components.

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
    [string]$Username,   

    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory = ".\docker_image_download",

    [Parameter(Mandatory=$false)]
    [string]$AuthRealm,

    [Parameter(Mandatory=$false)]
    [string]$AuthService
)

$ErrorActionPreference = "Stop" # Stop on errors

# Ensure output directory exists
if (-not (Test-Path $OutputDirectory)) {
    Write-Host "Creating output directory: $OutputDirectory"
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}
Write-Host "Image components will be saved to: $(Resolve-Path $OutputDirectory)"

function Discover-GitLabAuthParameters {
    param(
        [string]$CurrentRegistryUrl,
        [string]$InitialToken,
        [string]$InitialUsername
    )

    Write-Host "Attempting to discover authentication parameters from $CurrentRegistryUrl..."
    $discoveryUrl = "https://$($CurrentRegistryUrl)/v2/"
    $discoveryRequestParams = @{
        Uri = $discoveryUrl
        Method = "Get"
        Headers = @{
            "Accept" = "application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json"
        }
        SkipHttpErrorCheck = $true # We expect a 401
    }

    if ($InitialUsername) {
        $credential = New-Object System.Management.Automation.PSCredential($InitialUsername, (ConvertTo-SecureString $InitialToken -AsPlainText -Force))
        $discoveryRequestParams.Credential = $credential
    } elseif ($InitialToken) { # Original token as Bearer for discovery if no username
        $discoveryRequestParams.Headers["Authorization"] = "Bearer $InitialToken"
    }

    try {
        # Make a GET request to the /v2/ endpoint to trigger a 401 and get Www-Authenticate
        Invoke-RestMethod @discoveryRequestParams
    } catch [System.Net.WebException] {
        if ($_.Exception.Response -is [System.Net.HttpWebResponse] -and $_.Exception.Response.StatusCode -eq [System.Net.HttpStatusCode]::Unauthorized) {
            $response = $_.Exception.Response
            Write-Host "Received 401 from $discoveryUrl, attempting to parse Www-Authenticate header."
            $wwwAuthenticateHeader = $response.Headers['Www-Authenticate']
            if (-not [string]::IsNullOrEmpty($wwwAuthenticateHeader)) {
                Write-Host "Www-Authenticate header: $wwwAuthenticateHeader"
                # Example: Bearer realm="https://gitlab.example.com/jwt/auth",service="container_registry"
                if ($wwwAuthenticateHeader -match 'realm="([^"]*)"') {
                    $script:TokenRealm = $Matches[1]
                    Write-Host "Discovered Realm: $($script:TokenRealm)"
                } else {
                    Write-Warning "Could not parse realm from Www-Authenticate header."
                }

                if ($wwwAuthenticateHeader -match 'service="([^"]*)"') {
                    $script:TokenService = $Matches[1]
                    Write-Host "Discovered Service: $($script:TokenService)"
                } else {
                    Write-Warning "Could not parse service from Www-Authenticate header. Defaulting to 'container_registry'."
                    $script:TokenService = "container_registry"
                }
            } else {
                Write-Warning "Received 401 but Www-Authenticate header not found or empty."
            }
        } else {
            $statusCode = "Unknown"
            if ($null -ne $response) { $statusCode = $response.StatusCode }
            Write-Warning "Failed to discover auth params from $discoveryUrl. HTTP Status: $statusCode"
            if ($null -ne $response) { Write-Warning "Response Headers: $($response.Headers | Out-String)" }
        }
    }
}

# Discover auth parameters and apply overrides
Discover-GitLabAuthParameters -CurrentRegistryUrl $RegistryUrl -InitialToken $Token -InitialUsername $Username

if (-not [string]::IsNullOrEmpty($AuthRealm)) {
    Write-Host "Overriding discovered/default TokenRealm with command-line value: $AuthRealm"
    $script:TokenRealm = $AuthRealm
}
if (-not [string]::IsNullOrEmpty($AuthService)) {
    Write-Host "Overriding discovered/default TokenService with command-line value: $AuthService"
    $script:TokenService = $AuthService
}

if ([string]::IsNullOrEmpty($script:TokenRealm)) {
    Write-Error "Token Authentication Realm (TokenRealm) is not set. It could not be discovered and was not provided via -AuthRealm parameter. Cannot proceed with JWT authentication."
    exit 1
}
if ([string]::IsNullOrEmpty($script:TokenService)) {
    Write-Warning "TokenService is not set. Defaulting to 'container_registry'. Provide -AuthService if this is incorrect."
    $script:TokenService = "container_registry"
}

Write-Host "Using TokenRealm: $($script:TokenRealm)"
Write-Host "Using TokenService: $($script:TokenService)"

function Get-GitLabRegistryJwt {
    param(
        [string]$JwtRealm,
        [string]$JwtService,
        [string]$TargetImagePath,
        [string]$OriginalToken,
        [string]$OriginalUsername
    )

    Write-Host "Attempting to fetch JWT for registry..."
    $scope = "repository:$($TargetImagePath):pull"
    # For push, scope would be "repository:$TargetImagePath:pull,push"

    $tokenUrl = "$($JwtRealm)?service=$($JwtService)&scope=repository:$($ImagePath):pull"
    $bodyString = "grant_type=password&client_id=docker&access_type=offline"

    $tokenRequestParams = @{
        Uri = $tokenUrl
        Method = "Post"
        Headers = @{ "Content-Type" = "application/x-www-form-urlencoded" }
        Body = $bodyString
    }

    if ($OriginalUsername) {
        # For regular username/password (or PAT as password) to the token endpoint
        $credential = New-Object System.Management.Automation.PSCredential($OriginalUsername, (ConvertTo-SecureString $OriginalToken -AsPlainText -Force))
        $tokenRequestParams.Credential = $credential
    } else {
        # For PAT/Deploy token directly as Bearer to token endpoint if username not given
        $tokenRequestParams.Headers["Authorization"] = "Bearer $OriginalToken"
    }

    Write-Host "Requesting JWT from $tokenUrl (Username: $($OriginalUsername -ne $null))"
    # Write-Verbose "JWT Request Parameters: $($tokenRequestParams | Format-List | Out-String)" # Too verbose for normal operation

    try {
        $jwtResponse = Invoke-RestMethod @tokenRequestParams
        if ($jwtResponse.token) {
            $script:RegistryJwt = $jwtResponse.token
        } elseif ($jwtResponse.access_token) {
            $script:RegistryJwt = $jwtResponse.access_token
        } else {
            Write-Error "JWT not found in response from token server. Response: $($jwtResponse | ConvertTo-Json -Depth 5)"
            return $false
        }
        Write-Host "Successfully fetched JWT."
        return $true
    } catch {
        $statusCode = "Unknown"
        $responseContent = "No response content"
        if ($_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode
            $responseContent = $_.Exception.Response.Content
        }
        Write-Error "Failed to fetch JWT. Status: $statusCode | Response: $responseContent"
        $script:RegistryJwt = $null # Ensure JWT is cleared on failure
        return $false
    }
}

# Script-level variables for JWT auth
$script:RegistryJwt = $null
$script:TokenRealm = $null
$script:TokenService = $null

function Invoke-GitLabRegistryRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Uri,

        [Parameter(Mandatory=$true)]
        [hashtable]$Headers,

        [Parameter(Mandatory=$true)]
        [string]$Method,

        [string]$ContentType,

        [string]$OutFile,

        [switch]$AllowRetry = $true
    )

    $attempt = 1
    $maxAttempts = 2

    while ($attempt -le $maxAttempts) {
        Write-Verbose "Invoke-GitLabRegistryRequest: Attempt $attempt for $Uri"
        if ([string]::IsNullOrEmpty($script:RegistryJwt)) {
            Write-Verbose "No active JWT, attempting to fetch..."
            if (-not (Get-GitLabRegistryJwt -JwtRealm $script:TokenRealm -JwtService $script:TokenService -TargetImagePath $ImagePath -OriginalToken $Token -OriginalUsername $Username)) {
                Write-Error "Failed to obtain JWT for request to $Uri. Cannot proceed."
                throw "JWT acquisition failed."
            }
        }

        $requestHeaders = $Headers.Clone() # Clone to avoid modifying original headers object passed in
        $requestHeaders.Authorization = "Bearer $($script:RegistryJwt)"

        try {
            $invokeParams = @{
                Uri = $Uri
                Headers = $requestHeaders
                Method = $Method
                ErrorAction = 'Stop' # Ensure we catch errors to check status code
            }
            if (-not [string]::IsNullOrEmpty($ContentType)) {
                $invokeParams.ContentType = $ContentType
            }
            if (-not [string]::IsNullOrEmpty($OutFile)) {
                $invokeParams.OutFile = $OutFile
                # For OutFile, Invoke-RestMethod doesn't return body, so we just execute
                Invoke-RestMethod @invokeParams
                # To mimic bash script, we might need to return a synthetic success object or rely on no exception
                # For simplicity, if OutFile is used, success is no exception. Caller checks file existence/content.
                return $true # Indicate success for OutFile operations
            } else {
                return Invoke-RestMethod @invokeParams
            }
        } catch {
            $exceptionResponse = $_.Exception.Response
            if ($null -ne $exceptionResponse -and $exceptionResponse.StatusCode -eq [System.Net.HttpStatusCode]::Unauthorized) {
                Write-Warning "Request to $Uri failed with 401 (Unauthorized). Current JWT might be invalid or expired."
                $script:RegistryJwt = $null # Clear JWT
                if ($AllowRetry -and $attempt -lt $maxAttempts) {
                    Write-Host "Attempting to refresh JWT and retry request ($($attempt + 1)/$maxAttempts)..."
                    $attempt++
                    continue # Retry the while loop
                }
                Write-Error "Failed request to $Uri after JWT refresh attempt or retry disabled. Status: 401"
                throw $_ # Re-throw the original exception if retries exhausted or not allowed
            } else {
                # For other errors, just re-throw
                Write-Error "Request to $Uri failed. Status: $($exceptionResponse.StatusCode)"
                throw $_ 
            }
        }
    }
}

# 1. Fetch the manifest
# The manifest URL typically looks like: https://<registry_url>/v2/<image_name>/manifests/<tag_or_digest>
$manifestUrl = "https://$($RegistryUrl)/v2/$($ImagePath)/manifests/$($ImageTag)"
Write-Host "Fetching manifest from: $manifestUrl"

# Request multiple manifest types. The registry will return the most specific one it supports.
$manifestRequestHeaders = @{
    "Accept" = "application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json"
}

$manifestResponse = $null
try {
    $manifestResponse = Invoke-GitLabRegistryRequest -Uri $manifestUrl -Headers $manifestRequestHeaders -Method Get -ContentType "application/json"
} catch {
    Write-Error "Failed to fetch manifest from $manifestUrl after retries. Error: $($_.Exception.Message)"
    # Additional error details can be logged if needed from $_.Exception
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
    $specificArchManifestRequestHeaders = @{
        "Accept" = "application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json"
    }
    
    Write-Host "Fetching specific architecture manifest ($selectedManifestDigest) from: $specificManifestUrl"
    try {
        $actualManifest = Invoke-GitLabRegistryRequest -Uri $specificManifestUrl -Headers $specificArchManifestRequestHeaders -Method Get -ContentType "application/json"
    } catch {
        Write-Error "Failed to fetch specific architecture manifest $selectedManifestDigest from $specificManifestUrl after retries. Error: $($_.Exception.Message)"
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
$blobHeaders = @{}
# Add specific Accept header if needed for config, e.g., $blobHeaders.Accept = $imageConfigDescriptor.mediaType
# However, for direct blob downloads, often no specific Accept is strictly necessary beyond what the JWT provides.
try {
    Invoke-GitLabRegistryRequest -Uri $configUrl -Headers $blobHeaders -Method Get -OutFile $configOutputPath
    Write-Host "Image config saved to $configOutputPath"
} catch {
    Write-Error "Failed to download image config blob $configDigest from $configUrl after retries. Error: $($_.Exception.Message)"
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
    $blobHeaders = @{}
    # Add specific Accept header if needed for layer, e.g., $blobHeaders.Accept = $layerMediaType
    try {
        Invoke-GitLabRegistryRequest -Uri $layerUrl -Headers $blobHeaders -Method Get -OutFile $layerOutputPath
        Write-Host "Layer $layerDigest saved to $layerOutputPath"
    } catch {
        Write-Error "Failed to download layer $layerDigest from $layerUrl after retries. Error: $($_.Exception.Message)"
        exit 1 # Exiting on first layer failure for simplicity
    }
}

Write-Host "Image download process complete."
Write-Host "All components (manifests, config, layers) are saved in: $(Resolve-Path $OutputDirectory)"
Write-Host "Note: These are raw components. To use with 'docker load', they would need to be packaged into a specific tarball format."
