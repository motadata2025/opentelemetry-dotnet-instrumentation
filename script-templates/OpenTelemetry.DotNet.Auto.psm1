#
# Copyright The OpenTelemetry Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

#Requires -RunAsAdministrator
#Requires -Modules WebAdministration

$ServiceLocatorVariable = "OTEL_DOTNET_AUTO_INSTALL_DIR"

$OtelFilters = @(
    # .NET Framework
    "COR_ENABLE_PROFILING",
    "COR_PROFILER",
    "COR_PROFILER_PATH_32",
    "COR_PROFILER_PATH_64",
    # .NET Core
    "CORECLR_ENABLE_PROFILING",
    "CORECLR_PROFILER",
    "CORECLR_PROFILER_PATH_32",
    "CORECLR_PROFILER_PATH_64",
    # ASP.NET Core
    "ASPNETCORE_HOSTINGSTARTUPASSEMBLIES",
    # .NET Common
    "DOTNET_ADDITIONAL_DEPS",
    "DOTNET_SHARED_STORE",
    "DOTNET_STARTUP_HOOKS",
    # OpenTelemetry
    "OTEL_",
    # Additional
    "MOTADATA_INSTALLATION_PATH",
    "DOTNET_HOSTING_TYPE",
    "SERVICE_TYPE",
    "SERVICE_TRACE_STATE"
)

function Get-Current-InstallDir() {
    $installDir =[System.Environment]::GetEnvironmentVariable($ServiceLocatorVariable, [System.EnvironmentVariableTarget]::Machine)
    
    if (-not [string]::IsNullOrWhiteSpace($installDir) -and (Test-Path -Path $installDir -PathType Container)) {
        return $installDir
    }
    else {
        return $null
    }
    return 
}

function Get-CLIInstallDir-From-InstallDir([string]$InstallDir) {
    $dir = "Motadata .NET AutoInstrumentation"
    
    if ($InstallDir -eq "<auto>") {
        return (Join-Path $Env:ProgramFiles $dir)
    }
    elseif (Test-Path $InstallDir -IsValid) {
        return $InstallDir
    }

    throw "Invalid install directory provided '$InstallDir'"
}

function Get-Temp-Directory() {
    $temp = $env:TEMP

    if (-not (Test-Path $temp)) {
        New-Item -ItemType Directory -Force -Path $temp | Out-Null
    }

    return $temp
}

function Prepare-Install-Directory([string]$InstallDir) {
    if (Test-Path $InstallDir) {
        # Cleanup old directory
        Remove-Item -LiteralPath $InstallDir -Force -Recurse
    }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

function Reset-IIS() {    
    Start-Process "iisreset.exe" -NoNewWindow -Wait
}

function Ensure-IISCoreServices {
    foreach ($svc in "W3SVC","WAS") {
        $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if (-not $service) { 
            throw "Service $svc not found. IIS may not be installed." 
        }
        if ($service.Status -ne 'Running') {
            throw "Service $svc not Running." 
        }
    }
    Write-Output "IIS Core Services are running."
}

function Test-AppPoolExists {
    param([string]$Name)
    $pool = Get-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.applicationHost/applicationPools/add[@name='$Name']" -name "name"
    return $pool -ne $null
}

function Get-AppPoolVariables {
    param([string]$Name)
    $vars = @{}
    $envVars = Get-WebConfiguration -filter "system.applicationHost/applicationPools/add[@name='$Name']/environmentVariables/*"
    
    if (-not $envVars) { 
        return $vars 
    }

    foreach ($v in $envVars) {
        if ($v.name -and $v.value) { 
            $vars[$v.name] = $v.value 
        } 
    }

    return $vars
}

function Clear-AppPoolVariables {
    param([string]$Name)

     # Get current environment variables for this App Pool
    $vars = (Get-AppPoolVariables $Name).Keys

    if (-not $vars) {
        Write-Verbose "[$Name] No environment variables found. Skipping clear operation."
        return
    }

    # Find only matching OTEL-related variables
    $targetVars = @()
    foreach ($v in $vars) {
        foreach ($filter in $OtelFilters) {
            if ($v -like "$filter*" -or $v -eq $filter) {
                $targetVars += $v
                break
            }
        }
    }

    if (-not $targetVars) {
        Write-Verbose "[$Name] No OTEL-related environment variables found. Nothing to clear."
        return
    }

    # Remove only the matching ones
    foreach ($v in $targetVars) {
        Remove-WebConfigurationProperty `
            -filter "system.applicationHost/applicationPools/add[@name='$Name']/environmentVariables" `
            -name "." -AtElement @{ name = $v } `
            -ErrorAction SilentlyContinue

        Write-Verbose "[$Name] Removed environment variable: $v"
    }
}

function Set-AppPoolVariables {
    param([string]$Name,[hashtable]$Vars)
    foreach ($kv in $Vars.GetEnumerator()) {
        
        $existing = Get-WebConfiguration `
            -filter "system.applicationHost/applicationPools/add[@name='$Name']/environmentVariables/add[@name='$($kv.Key)']" `
            -ErrorAction SilentlyContinue

        if ($existing) {
            Set-WebConfigurationProperty `
                -filter "system.applicationHost/applicationPools/add[@name='$Name']/environmentVariables/add[@name='$($kv.Key)']" `
                -name "value" -value $kv.Value
        } else {
            Add-WebConfigurationProperty `
                -filter "system.applicationHost/applicationPools/add[@name='$Name']/environmentVariables" `
                -name "." -value @{name=$kv.Key; value=$kv.Value}
        }
    }
}

<#
    .SYNOPSIS
    Ensures that IIS core services (W3SVC, WAS) do not carry OTEL environment variables.
    If found, calls Unregister-OpenTelemetryForIIS to clear them and restart IIS.
#>
function Ensure-IISNotGloballyInstrumented {

    $services = @("W3SVC", "WAS")
    $needsCleanup = $false

    foreach ($svc in $services) {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
        try {
            $envVars = (Get-ItemProperty -Path $regPath -Name "Environment" -ErrorAction SilentlyContinue).Environment
            if ($envVars) {
                foreach ($entry in $envVars) {
                    if ($entry -like "OTEL_*") {
                        Write-Verbose "[$svc] Found OpenTelemetry variable: $entry"
                        $needsCleanup = $true
                        break
                    }
                }
            }
        }
        catch {
            Write-Verbose "[$svc] No Environment registry key found. Skipping."
        }
    }

    if ($needsCleanup) {
        Write-Output "Global IIS OpenTelemetry instrumentation detected. Cleaning up..."
        Unregister-OpenTelemetryForIIS
    }
    else {
        Write-Verbose "No global IIS OpenTelemetry instrumentation found."
    }
}


function Export-EnvironmentVariablesFromPropertiesFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OtelServiceName
    )

    $propertiesFilePath = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\config\$OtelServiceName.properties")

    if (-not (Test-Path $PropertiesFilePath)) {
        throw "Properties file '$PropertiesFilePath' not found."
    }

    $exportedVars = @{}

    # Read the file and filter out empty lines or comment lines
    $lines = Get-Content $PropertiesFilePath | Where-Object { $_ -and $_ -notmatch '^\s*#' }
    foreach ($line in $lines) {
        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) {
            $key = $parts[0].Trim()
            $value = $parts[1].Trim()

            # Transform the key to uppercase and replace '.' with '_'
            $envKey = $key -replace '\.', '_' | ForEach-Object { $_.ToUpper() }
	        $valueKey = $value -replace '\\', ''	
    
            Write-Verbose "Setting environment variable '$envKey' to '$value' from properties file."

            # Construct the variable string as expected in the environment
            $exportedVars.Add($envKey, $valueKey)
        }
    }

    return $exportedVars
}

function Get-Environment-Variables-Table([string]$InstallDir, [string]$OTelServiceName) {
    $COR_PROFILER_PATH_32 = Join-Path $InstallDir "/win-x86/OpenTelemetry.AutoInstrumentation.Native.dll"
    $COR_PROFILER_PATH_64 = Join-Path $InstallDir "/win-x64/OpenTelemetry.AutoInstrumentation.Native.dll"
    $CORECLR_PROFILER_PATH_32 = Join-Path $InstallDir "/win-x86/OpenTelemetry.AutoInstrumentation.Native.dll"
    $CORECLR_PROFILER_PATH_64 = Join-Path $InstallDir "/win-x64/OpenTelemetry.AutoInstrumentation.Native.dll"

    $DOTNET_ADDITIONAL_DEPS = Join-Path $InstallDir "AdditionalDeps"
    $DOTNET_SHARED_STORE = Join-Path $InstallDir "store"
    $DOTNET_STARTUP_HOOKS = Join-Path $InstallDir "net/OpenTelemetry.AutoInstrumentation.StartupHook.dll"

    $OTEL_DOTNET_AUTO_HOME = $InstallDir
    
    $vars = @{
        # .NET Framework
        "COR_ENABLE_PROFILING"                = "1";
        "COR_PROFILER"                        = "{918728DD-259F-4A6A-AC2B-B85E1B658318}";
        "COR_PROFILER_PATH_32"                = $COR_PROFILER_PATH_32;
        "COR_PROFILER_PATH_64"                = $COR_PROFILER_PATH_64;
        # .NET Core
        "CORECLR_ENABLE_PROFILING"            = "1";
        "CORECLR_PROFILER"                    = "{918728DD-259F-4A6A-AC2B-B85E1B658318}";
        "CORECLR_PROFILER_PATH_32"            = $CORECLR_PROFILER_PATH_32;
        "CORECLR_PROFILER_PATH_64"            = $CORECLR_PROFILER_PATH_64;
        # ASP.NET Core
        "ASPNETCORE_HOSTINGSTARTUPASSEMBLIES" = "OpenTelemetry.AutoInstrumentation.AspNetCoreBootstrapper";
        # .NET Common
        "DOTNET_ADDITIONAL_DEPS"              = $DOTNET_ADDITIONAL_DEPS;
        "DOTNET_SHARED_STORE"                 = $DOTNET_SHARED_STORE;
        "DOTNET_STARTUP_HOOKS"                = $DOTNET_STARTUP_HOOKS;
        # OpenTelemetry
        "OTEL_DOTNET_AUTO_HOME"               = $OTEL_DOTNET_AUTO_HOME;
        # Motadata Installation Path
        "MOTADATA_INSTALLATION_PATH"          = $PSScriptRoot;
    }

    if (-not [string]::IsNullOrWhiteSpace($OTelServiceName)) {
        $vars.Add("OTEL_SERVICE_NAME", $OTelServiceName)
    }

    # Get new variables from the properties file
    $exportedVarsTable = Export-EnvironmentVariablesFromPropertiesFile -OtelServiceName $OTelServiceName

    # Merge $exportedVarsTable into $varsTable (overwriting existing keys or adding new ones)
    foreach ($key in $exportedVarsTable.Keys) {
        $vars[$key] = $exportedVarsTable[$key]
    }

    return $vars
}

function Setup-Windows-Service([string]$InstallDir, [string]$WindowsServiceName, [string]$OTelServiceName) {  
    Install-OpenTelemetryCore
    $varsTable = Get-Environment-Variables-Table -InstallDir $InstallDir -OTelServiceName $OTelServiceName
    $regPath = "HKLM:SYSTEM\CurrentControlSet\Services\"
    $regKey = Join-Path $regPath $WindowsServiceName
   
    if (Test-Path $regKey) {
        # Cleanup existing variables
        Cleanup-Environment-Variables -WindowsServiceName $WindowsServiceName

        # Migrate remaining external variables to install variables
        [string []] $varsList = Migrate-Environment-Variables -ServiceRegistryKey $regKey -InstallVars $varsTable
        
        # Set install variables
        Set-ItemProperty $regKey -Name Environment -Value $varsList
    }
    else {
        throw "Invalid service '$WindowsServiceName'. Service does not exist."
    }
}

function Cleanup-Environment-Variables([string]$WindowsServiceName) {
    $regPath = "HKLM:SYSTEM\CurrentControlSet\Services\"
    $regKey = Join-Path $regPath $WindowsServiceName
   
    if (Test-Path $regKey) {
        $property = Get-ItemProperty $regKey
        if (-not $property.Environment) {
            # Nothing to clean
            return
        }

        $vars = Filter-Env-List -EnvValues $property.Environment -Filters $OtelFilters

        Set-ItemProperty $regKey -Name Environment -Value $vars
    }
    else {
        throw "Invalid service '$WindowsServiceName'. Service does not exist."
    }

    $remaining = Get-ItemPropertyValue $regKey -Name Environment
    if (-not $remaining) {
        Remove-ItemProperty $regKey -Name Environment
    }
}

function Migrate-Environment-Variables([string]$ServiceRegistryKey, [hashtable]$InstallVars) {
    $prop = Get-ItemProperty $ServiceRegistryKey

    if ($prop.Environment){
        foreach ($var in $prop.Environment) {
            # Split the string on the first '=' to get the key and value
            $splitVar = $var.Split('=', 2)
            $key = $splitVar[0]
            $value = $splitVar[1]

            # Reinstall external variable
            $InstallVars[$key] = $value
        }
    }

    [string []] $varsList = $InstallVars.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } # [string []] definition is required for WS2016

    return $varsList
}

function Filter-Env-List([string[]]$EnvValues, [string[]]$Filters) {
    $remaining = @()

    foreach ($value in $EnvValues) {
        $match = $false

        foreach ($filter in $Filters) {
            if ($value -clike "$($filter)*") {
                $match = $true
                break
            }
        }

        if (-not $match) {
            $remaining += $value
        }
    }

    return $remaining
}

function Get-OpenTelemetry-Archive([string] $LocalPath) {
    if ($LocalPath) {
        if (Test-Path $LocalPath) {
            return $LocalPath
        }

        throw "Could not find archive '$LocalPath'"
    }

}

function Test-AssemblyNotForGAC([string] $Name) {
    switch ($Name) {
        "netstandard.dll" { return $true }
        "grpc_csharp_ext.x64.dll" { return $true }
        "grpc_csharp_ext.x86.dll" { return $true }
    }
    return $false 
}

function Is-Greater-Version($v1, $v2) {
    # Helper convert version main part to version object
    function ToVersion($version) {
        return ($version -replace '^v' -replace '-.+$') -as [version]
    }

    # Helper convert version pre part to version object
    function RankPre($version) {
        # $null is full release
        $rank = "alpha", "beta", "rc", $null
        $ranked = $null

        if ($version -match "^v\d+\.\d+\.\d+?(\-(?<pre>[\w\.]+))") {
            $token = $matches['pre'].split('.')[0]
            $ranked = $matches['pre'] -replace $token, $rank.IndexOf($token)
        }
        else {
            $ranked = $rank.IndexOf($null)
            $ranked = "$($ranked).0"
        }

        return $ranked -as [version]
    }

    $v1Version = ToVersion $v1
    $v2Version = ToVersion $v2

    if ($v1Version -gt $v2Version) { return $true }
    if ($v1Version -lt $v2Version) { return $false }

    $v1PreRank = RankPre $v1
    $v2PreRank = RankPre $v2

    if ($v1PreRank -gt $v2PreRank) { return $true }

    return $false;
}

# --- Helper function: Checks .NET version and sets LoaderOptimization ---
function Ensure-DotNetLoaderOptimization {
    [CmdletBinding()]
    param (
        [int]$MinimumRelease = 394802  # .NET 4.6.2
    )

    Write-Host "Verifying .NET Framework and LoaderOptimization..."

    # Function to check if .NET Framework is installed
    function Test-DotNetFramework {
        param ([int]$MinimumRelease)

        $regPaths = @(
            "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\NET Framework Setup\NDP\v4\Full"
        )

        foreach ($path in $regPaths) {
            if (Test-Path $path) {
                try {
                    $release = (Get-ItemProperty $path -Name Release -ErrorAction Stop).Release
                    if ($release -ge $MinimumRelease) { return $true }
                } catch { }
            }
        }
        return $false
    }

    # Function to set LoaderOptimization registry value
    function Set-LoaderOptimization {
        param ([string]$RegPath)

        try {
            if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }

            $currentValue = Get-ItemProperty -Path $RegPath -Name "LoaderOptimization" -ErrorAction SilentlyContinue

            if ($null -eq $currentValue.LoaderOptimization -or $currentValue.LoaderOptimization -ne 1) {
                Set-ItemProperty -Path $RegPath -Name "LoaderOptimization" -Value 1 -Type DWord
                Write-Host "LoaderOptimization set to 1 in $RegPath"
            } else {
                Write-Host "LoaderOptimization already set in $RegPath"
            }
        } catch {
            Write-Warning "Failed to set LoaderOptimization in $RegPath. Error: $_"
        }
    }

    # --- Execution ---
    if (-not (Test-DotNetFramework -MinimumRelease $MinimumRelease)) {
        Write-Warning ".NET Framework 4.6.2 or higher is required."
        return $false
    }

    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\.NETFramework",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework"
    )

    foreach ($regPath in $regPaths) { Set-LoaderOptimization -RegPath $regPath }

    return $true
}

<#
    .SYNOPSIS
    Installs OpenTelemetry .NET Automatic Instrumentation.
    .PARAMETER InstallDir
    Default: <auto> - the default path is Program Files dir.
    Install path of the OpenTelemetry .NET Automatic Instrumentation
    Possible values: <auto>, (Custom path)
#>
function Install-OpenTelemetryCore() {
    param(
        [Parameter(Mandatory = $false)]
        [string]$InstallDir = "<auto>",
        [Parameter(Mandatory = $false)]
        [string]$LocalPath
    )

    $installDir = Get-CLIInstallDir-From-InstallDir $InstallDir
    $archivePath = $null
    $LocalPath = Join-Path $PSScriptRoot "motadata-dotnet-win.zip"


    try {
        $archivePath = Get-OpenTelemetry-Archive $LocalPath

        if(Test-Path $installDir){
            return $true | Out-Null
        }

        Prepare-Install-Directory $installDir

        # Extract files from zip
        Expand-Archive $archivePath $installDir -Force

        # OpenTelemetry service locator
        [System.Environment]::SetEnvironmentVariable($ServiceLocatorVariable, $installDir, [System.EnvironmentVariableTarget]::Machine)

        # Register .NET Framework dlls in GAC
        [System.Reflection.Assembly]::Load("System.EnterpriseServices, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a") | Out-Null
        $publish = New-Object System.EnterpriseServices.Internal.Publish 
        $dlls = Get-ChildItem -Path $installDir\netfx\ -Filter *.dll -File
        for ($i = 0; $i -lt $dlls.Count; $i++) {
            $percentageComplete = $i / $dlls.Count * 100
            Write-Progress -Activity "Registering .NET Framework dlls in GAC" `
                -Status "Module $($i+1) out of $($dlls.Count). Installing $($dlls[$i].Name):" `
                -PercentComplete $percentageComplete

            if (Test-AssemblyNotForGAC $dlls[$i].Name) {
                continue
            }

            $publish.GacInstall($dlls[$i].FullName)
        }
        Write-Progress -Activity "Registering .NET Framework dlls in GAC" -Status "Ready" -Completed

        # --- Safely ensure LoaderOptimization at the end ---
        try {
            Ensure-DotNetLoaderOptimization
        } catch {
            Write-Warning "Could not set LoaderOptimization: $_"
        }
    } 
    catch {
        $message = $_
        Write-Error "Could not setup OpenTelemetry .NET Automatic Instrumentation. $message"
    } 
}

<#
    .SYNOPSIS
    Uninstalls OpenTelemetry .NET Automatic Instrumentation.
#>
function Uninstall-OpenTelemetryCore() {
    $installDir = Get-Current-InstallDir

    if (-not $installDir) {
        throw "OpenTelemetry Core is already removed."
    }

    # Unregister .NET Framwework dlls from GAC
    [System.Reflection.Assembly]::Load("System.EnterpriseServices, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a") | Out-Null
    $publish = New-Object System.EnterpriseServices.Internal.Publish 
    $dlls = Get-ChildItem -Path $installDir\netfx\ -Filter *.dll -File
    for ($i = 0; $i -lt $dlls.Count; $i++) {
        $percentageComplete = $i / $dlls.Count * 100
        Write-Progress -Activity "Unregistering .NET Framework dlls from GAC" `
            -Status "Module $($i+1) out of $($dlls.Count). Uninstalling $($dlls[$i].Name):" `
            -PercentComplete $percentageComplete

        if (Test-AssemblyNotForGAC $dlls[$i].Name) {
            continue
        }

        $publish.GacRemove($dlls[$i].FullName)
    }
    Write-Progress -Activity "Unregistering .NET Framework dlls from GAC" -Status "Ready" -Completed

    Remove-Item -LiteralPath $installDir -Force -Recurse

    # Remove OTel service locator variable
    [System.Environment]::SetEnvironmentVariable($ServiceLocatorVariable, $null, [System.EnvironmentVariableTarget]::Machine)
}

<#
    .SYNOPSIS
    Setups environment variables to enable automatic instrumentation started from the current PowerShell session.
    .PARAMETER OTelServiceName
    Specifies OpenTelemetry service name to identify your service.
#>
function Register-OpenTelemetryForCurrentSession() {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OTelServiceName
    )

    Install-OpenTelemetryCore
    $installDir = Get-Current-InstallDir

    if (-not $installDir) {
        throw "OpenTelemetry Core must be setup first. Run 'Install-OpenTelemetryCore' to setup OpenTelemetry Core."
    }

    $varsTable = Get-Environment-Variables-Table -InstallDir $installDir -OTelServiceName $OTelServiceName

    foreach ($var in $varsTable.Keys) {
        Set-Item "env:$var" $varsTable[$var]
    }
}

<#
    .SYNOPSIS
    Setups IIS environment variables to enable automatic instrumentation.
    Performs IIS reset after registration.
#>
function Register-OpenTelemetryForIIS() {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OTelServiceName
    )
    $installDir = Get-Current-InstallDir

    if (-not $installDir) {
        Install-OpenTelemetryCore
        $installDir = Get-Current-InstallDir

        if (-not $installDir) {
            throw "OpenTelemetry Core must be setup first. Run 'Install-OpenTelemetryCore' to setup OpenTelemetry Core."
        }
    }

    if ($installDir -notlike "$env:ProgramFiles\*") {
        Write-Warning "OpenTelemetry is installed to custom path. Make sure that IIS user has access to the path."
    }

    Setup-Windows-Service -InstallDir $installDir -WindowsServiceName "W3SVC" -OTelServiceName $OTelServiceName
    Setup-Windows-Service -InstallDir $installDir -WindowsServiceName "WAS" -OTelServiceName $OTelServiceName

    Reset-IIS
}

<#
    .SYNOPSIS
    Setups specific Windows service environment variables to enable automatic instrumentation.
    Performs service restart after registration.
    .PARAMETER WindowsServiceName
    Actual Windows service name in registry.
    .PARAMETER OTelServiceName
    Specifies OpenTelemetry service name to identify your service.
#>
function Register-OpenTelemetryForWindowsService() {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowsServiceName,
        [Parameter(Mandatory = $true)]
        [string]$OTelServiceName
    )

    $installDir = Get-Current-InstallDir

    if (-not $installDir) {
        Install-OpenTelemetryCore
        $installDir = Get-Current-InstallDir

        if (-not $installDir) {
            throw "OpenTelemetry Core must be setup first. Run 'Install-OpenTelemetryCore' to setup OpenTelemetry Core."
        }
    }

    Setup-Windows-Service -InstallDir $installDir -WindowsServiceName $WindowsServiceName -OTelServiceName $OTelServiceName
    Restart-Service -Name $WindowsServiceName -Force
}

<#
    .SYNOPSIS
    Setups specific IIS AppPool environment variables to enable automatic instrumentation.
    Performs IIS AppPool recycle after registration.
    .PARAMETER AppPoolName
    Actual AppPool name in IIS.
    .PARAMETER OTelServiceName
    Specifies OpenTelemetry service name to identify your service.
#>
function Register-OpenTelemetryForIISAppPool {
    param(
        [Parameter(Mandatory = $true)] 
            [string]$AppPoolName,
        [Parameter(Mandatory = $true)] 
            [string]$OTelServiceName
    )

    Import-Module WebAdministration -ErrorAction Stop
    try{

        Ensure-IISCoreServices
    
        Ensure-IISNotGloballyInstrumented
    
        $installPath = Get-Current-InstallDir
        
        if (-not $installPath) { 
            Write-Verbose "OpenTelemetry not found, attempting to install..."
            Install-OpenTelemetryCore
            $installPath = Get-Current-InstallDir
    
            if (-not $installPath) { 
                throw "OpenTelemetry not installed. Without OpenTelemetry installed, automatic instrumentation cannot be enabled." 
            }
        }
    
        if (-not (Test-AppPoolExists -Name $AppPoolName)) {
            throw "AppPool '$AppPoolName' not found." 
        }
    
        # Build required variables
        $poolVars = Get-Environment-Variables-Table -InstallDir $installPath -OTelServiceName $OTelServiceName
    
        Write-Output "Preparing environment variables for AppPool '$AppPoolName'..."
        Clear-AppPoolVariables -Name $AppPoolName
    
        Write-Output "Setting AppPool environment variables..."
        Set-AppPoolVariables -Name $AppPoolName -Vars $poolVars
    
        try {
            Write-Output "Recycling AppPool '$AppPoolName'..."
            Restart-WebAppPool -Name $AppPoolName -ErrorAction Stop
        }
        catch {
            $reason = $_.Exception.Message
            Write-Warning "AppPool recycle not possible: $reason"
            # Interactive prompt in terminal
            $answer = Read-Host -Prompt "AppPool recycle not possible. Do you want to restart IIS (iisreset) instead? (Y/N)"
            if ($answer -match '^[Yy]') {
                Write-Output "Restarting IIS (this will briefly interrupt all sites)..."
                try {
                    Start-Process -FilePath "iisreset.exe" -ArgumentList "/restart" -Wait -NoNewWindow -ErrorAction Stop
                    Start-Sleep -Seconds 3
                    Write-Output "Attempting AppPool recycle again..."
                    Restart-WebAppPool -Name $AppPoolName -ErrorAction Stop
                }
                catch {
                    throw "Failed to recover AppPool '$AppPoolName' after IIS restart: $($_.Exception.Message)"
                }
            }
            else {
                Write-Output "Skipping IIS restart and leaving AppPool state as-is. You can restart the apppool later manually."
            }
        }
        Write-Output "OpenTelemetry registered for AppPool '$AppPoolName'"
    }
    catch {
        Write-Error "Failed to register OpenTelemetry for AppPool '$AppPoolName': $($_.Exception.Message)"
    }
}

<#
    .SYNOPSIS
    Removes environment variables to disable automatic instrumentation started from the current PowerShell session.
#>
function Unregister-OpenTelemetryForCurrentSession() {
    # .NET Framework
    $env:COR_ENABLE_PROFILING = $null
    $env:COR_PROFILER = $null
    $env:COR_PROFILER_PATH_32 = $null
    $env:COR_PROFILER_PATH_64 = $null

    # .NET Core
    $env:CORECLR_ENABLE_PROFILING = $null
    $env:CORECLR_PROFILER = $null
    $env:CORECLR_PROFILER_PATH_32 = $null
    $env:CORECLR_PROFILER_PATH_64 = $null

    # ASP.NET Core
    $env:ASPNETCORE_HOSTINGSTARTUPASSEMBLIES = $null

    # .NET Common
    $env:DOTNET_ADDITIONAL_DEPS = $null
    $env:DOTNET_SHARED_STORE = $null
    $env:DOTNET_STARTUP_HOOKS = $null

    # OpenTelemetry
    Get-ChildItem env: | Where-Object { $_.Name -like "OTEL_DOTNET_*" } | ForEach-Object { Set-Item "env:$($_.Name)" $null }
}

<#
    .SYNOPSIS
    Removes IIS environment variables to disable automatic instrumentation.
    Performs IIS reset after removal by default.
    .PARAMETER NoReset
    Does not perform IIS reset.
#>
function Unregister-OpenTelemetryForIIS() {
    param(
        [Parameter(Mandatory = $false)]
        [bool]$NoReset = $false
    )

    Cleanup-Environment-Variables -WindowsServiceName "W3SVC"
    Cleanup-Environment-Variables -WindowsServiceName "WAS"

    if (-not $NoReset) {
        Reset-IIS
    }
}

<#
    .SYNOPSIS
    Removes specific Windows service environment variables to disable automatic instrumentation.
    Performs service restart after removal.
    .PARAMETER WindowsServiceName
    Actual Windows service Name in registry.
#>
function Unregister-OpenTelemetryForWindowsService() {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowsServiceName
    )  

    Cleanup-Environment-Variables -WindowsServiceName $WindowsServiceName
    Restart-Service -Name $WindowsServiceName -Force
}

<#
    .SYNOPSIS
    Removes specific IIS AppPool environment variables to disable automatic instrumentation.
    Performs IIS AppPool reset after removal by default.
    .PARAMETER AppPoolName
    Actual AppPool name in IIS.
    .PARAMETER NoReset
    Does not perform IIS AppPool reset.
#>
function Unregister-OpenTelemetryForIISAppPool() {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppPoolName,
        [Parameter(Mandatory = $false)]
        [bool]$NoReset = $false
    )

    Import-Module WebAdministration -ErrorAction Stop
    try{
        Ensure-IISCoreServices
    
        if (-not (Test-AppPoolExists -Name $AppPoolName)) {
            throw "AppPool '$AppPoolName' not found." 
        }
    
        Write-Output "Clearing environment variables for AppPool '$AppPoolName'..."
        Clear-AppPoolVariables -Name $AppPoolName
    
        if (-not $NoRestart) {
            try {
                Write-Output "Recycling AppPool '$AppPoolName'..."
                Restart-WebAppPool -Name $AppPoolName -ErrorAction Stop
            }
            catch {
                $reason = $_.Exception.Message
                Write-Warning "AppPool recycle not possible: $reason"
                # Interactive prompt in terminal
                $answer = Read-Host -Prompt "AppPool recycle not possible. Do you want to restart IIS (iisreset) instead? (Y/N)"
                if ($answer -match '^[Yy]') {
                    Write-Output "Restarting IIS (this will briefly interrupt all sites)..."
                    try {
                        Start-Process -FilePath "iisreset.exe" -ArgumentList "/restart" -Wait -NoNewWindow -ErrorAction Stop
                        Start-Sleep -Seconds 3
                        Write-Output "Attempting AppPool recycle again..."
                        Restart-WebAppPool -Name $AppPoolName -ErrorAction Stop
                    }
                    catch {
                        throw "Failed to recover AppPool '$AppPoolName' after IIS restart: $($_.Exception.Message)"
                    }
                }
                else {
                    Write-Output "Skipping IIS restart and leaving AppPool state as-is. You can restart the apppool later manually."
                }
            }
        }
    
        Write-Host "Successfully removed OpenTelemetry environment variables from AppPool '$AppPoolName'"
    }
    catch {
        Write-Error "Failed to unregister OpenTelemetry for AppPool '$AppPoolName': $($_.Exception.Message)"
    }
}

<#
    .SYNOPSIS
    Locates OpenTelemetry .NET Automatic Instrumentation's install path. 
#>
function Get-OpenTelemetryInstallDirectory() {
    $installDir = Get-Current-InstallDir

    if ($installDir) {
        return $installDir
    }

    Write-Warning "OpenTelemetry .NET Automatic Instrumentation is not installed."
}

<#
    .SYNOPSIS
    Gets OpenTelemetry .NET Automatic Instrumentation install version. 
#>
function Get-OpenTelemetryInstallVersion() {
    $installDir = Get-OpenTelemetryInstallDirectory

    if ($installDir) {
        $mainDllPath = [IO.Path]::Combine($installDir, 'net', 'OpenTelemetry.AutoInstrumentation.dll')

        return "v" + ([System.Diagnostics.FileVersionInfo]::GetVersionInfo($mainDllPath).ProductVersion).split('+', 2)[0]
    }
}

<#
    .SYNOPSIS
    Enables OpenTelemetry .NET Automatic Instrumentation for IIS AppPool
    .PARAMETER AppPoolName
    IIS AppPool name
#>
function Enable-OpenTelemetryForIISAppPool() {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppPoolName
    ) 

    Remove-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.applicationHost/applicationPools/add[@name='$($AppPoolName)']/environmentVariables" -name "." -AtElement @{name='COR_ENABLE_PROFILING'}
}

<#
    .SYNOPSIS
    Disables OpenTelemetry .NET Automatic Instrumentation for IIS AppPool
    .PARAMETER AppPoolName
    IIS AppPool name
#>
function Disable-OpenTelemetryForIISAppPool() {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppPoolName
    )

    Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.applicationHost/applicationPools/add[@name='$($AppPoolName)']/environmentVariables" -name "." -value @{name='COR_ENABLE_PROFILING';value='0'}
}

Export-ModuleMember -Function Register-OpenTelemetryForIISAppPool
Export-ModuleMember -Function Register-OpenTelemetryForWindowsService
Export-ModuleMember -Function Register-OpenTelemetryForCurrentSession
#Export-ModuleMember -Function Register-OpenTelemetryForIIS

#Export-ModuleMember -Function Unregister-OpenTelemetryForIISAppPool