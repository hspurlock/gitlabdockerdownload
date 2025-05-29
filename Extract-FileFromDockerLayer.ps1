<#
.SYNOPSIS
    Extracts a specific file from a Docker image layer tarball.

.DESCRIPTION
    This script takes a Docker image layer file (typically a .tar or .tar.gz archive),
    the relative path of a file within that archive, and an output directory.
    It extracts the specified file to the given output directory.

.PARAMETER LayerFilePath
    The full path to the Docker layer file (e.g., 'layers/abc123xyz.tar.gz' or 'layers/def456uvw.tar').
    This file should be a tarball, possibly gzipped.

.PARAMETER FileToExtractPathInLayer
    The relative path of the file to extract from within the layer's archive.
    This path should match how it's stored in the tarball (e.g., 'app/config.ini', 'usr/local/bin/myexecutable').
    Leading slashes are often problematic for tar extraction, so prefer paths like 'etc/myconfig' over '/etc/myconfig'.
    You might need to list the tar contents first (e.g., using 'tar -tvf') to confirm the exact path.

.PARAMETER OutputDirectory
    The directory where the extracted file will be saved.
    If the directory does not exist, the script will attempt to create it.

.PARAMETER OutputFileName
    Optional. The name to give the extracted file in the OutputDirectory.
    If not specified, the original filename from the archive will be used.

.EXAMPLE
    .\Extract-FileFromDockerLayer.ps1 -LayerFilePath ".\docker_image_download\layers\sha256_some_layer_digest.tar.gz" -FileToExtractPathInLayer "app/settings.json" -OutputDirectory ".\extracted_files"
    This command extracts 'app/settings.json' from the specified layer and saves it as 'settings.json' in the '.\extracted_files' directory.

.EXAMPLE
    .\Extract-FileFromDockerLayer.ps1 -LayerFilePath ".\layer.tar" -FileToExtractPathInLayer "usr/local/share/data.txt" -OutputDirectory ".\output" -OutputFileName "my_data.txt"
    This command extracts 'usr/local/share/data.txt' from 'layer.tar' and saves it as 'my_data.txt' in the '.\output' directory.

.NOTES
    Requires PowerShell 5.0 or later for Expand-Archive with .tar.gz support.
    The script extracts the entire layer to a temporary location first, then copies the desired file.
    The temporary location is cleaned up afterwards.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$LayerFilePath,

    [Parameter(Mandatory=$true)]
    [string]$FileToExtractPathInLayer,

    [Parameter(Mandatory=$true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory=$false)]
    [string]$OutputFileName
)

$ErrorActionPreference = "Stop"

# Validate LayerFilePath
if (-not (Test-Path $LayerFilePath -PathType Leaf)) {
    Write-Error "Layer file not found: $LayerFilePath"
    exit 1
}

# Ensure OutputDirectory exists
if (-not (Test-Path $OutputDirectory -PathType Container)) {
    try {
        Write-Host "Output directory not found. Creating: $OutputDirectory"
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    } catch {
        Write-Error "Failed to create output directory '$OutputDirectory': $($_.Exception.Message)"
        exit 1
    }
}

# Sanitize FileToExtractPathInLayer: remove leading slashes as they can cause issues with Join-Path and tar structures
$NormalizedFileToExtractPath = $FileToExtractPathInLayer.TrimStart('/')
$NormalizedFileToExtractPath = $NormalizedFileToExtractPath.TrimStart('\\')

# Determine the final output file name
$FinalOutputFileName = if ([string]::IsNullOrWhiteSpace($OutputFileName)) {
    Split-Path -Path $NormalizedFileToExtractPath -Leaf # Get original filename
} else {
    $OutputFileName
}

$FinalOutputFilePath = Join-Path -Path $OutputDirectory -ChildPath $FinalOutputFileName

# Create a temporary directory for extraction
$TempExtractDir = Join-Path $OutputDirectory "temp_layer_extract_$(Get-Random)"

try {
    Write-Host "Creating temporary extraction directory: $TempExtractDir"
    New-Item -ItemType Directory -Path $TempExtractDir -Force | Out-Null

    Write-Host "Extracting layer '$LayerFilePath' to temporary directory..."
    Expand-Archive -Path $LayerFilePath -DestinationPath $TempExtractDir -Force
    Write-Host "Layer extraction complete."

    # Construct the full path to the target file within the temporary extracted contents
    $SourceFilePathInTemp = Join-Path -Path $TempExtractDir -ChildPath $NormalizedFileToExtractPath

    if (Test-Path $SourceFilePathInTemp -PathType Leaf) {
        Write-Host "File '$NormalizedFileToExtractPath' found in layer. Copying to '$FinalOutputFilePath'..."
        Copy-Item -Path $SourceFilePathInTemp -Destination $FinalOutputFilePath -Force
        Write-Host "File successfully extracted to: $FinalOutputFilePath"
    } else {
        Write-Error "File '$NormalizedFileToExtractPath' not found within the extracted layer content at '$SourceFilePathInTemp'."
        Write-Warning "Please ensure the path is correct. You can list tar contents using 'tar -tvf <layer_file>' or by manually inspecting the '$TempExtractDir' directory before it's cleaned up (by commenting out the finally block's Remove-Item)."
        exit 1
    }
} catch {
    Write-Error "An error occurred during extraction: $($_.Exception.Message)"
    # Consider leaving TempExtractDir for debugging if an error occurs, or provide an option
    exit 1
} finally {
    # Clean up the temporary directory
    if (Test-Path $TempExtractDir -PathType Container) {
        Write-Host "Cleaning up temporary directory: $TempExtractDir"
        Remove-Item -Recurse -Force -Path $TempExtractDir
    }
}

Write-Host "Process complete."
