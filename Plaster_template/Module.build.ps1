#requires -modules InvokeBuild

<#
.SYNOPSIS
    Build script (https://github.com/nightroman/Invoke-Build)

.DESCRIPTION
    This script contains the tasks for building the PowerShell module
#>

Param (
    [Parameter(ValueFromPipelineByPropertyName = $true)]
    [ValidateSet('Debug', 'Release')]
    [String]
    $Configuration = 'Debug',
    [Parameter(ValueFromPipelineByPropertyName = $true)]
    [ValidateNotNullOrEmpty()]
    [String]
    $SourceLocation,
    [Parameter(ValueFromPipelineByPropertyName = $true)]
    [ValidateNotNullOrEmpty()]
    [String]
    $ADOPat,
    [Parameter(ValueFromPipelineByPropertyName = $true)]
    [ValidateNotNullOrEmpty()]
    [String]
    $acceptableCodeCoveragePercent,
    [Parameter(ValueFromPipelineByPropertyName = $true)]
    [ValidateNotNullOrEmpty()]
    [String]
    $ModuleName
)

Set-StrictMode -Version Latest

# Synopsis: Default task
task . Clean, Build


# Install build dependencies
Enter-Build {

    # Installing PSDepend for dependency management
    if (-not (Get-Module -Name PSDepend -ListAvailable)) {
        Install-Module PSDepend -Force
    }
    Import-Module PSDepend

    # Installing dependencies
    Invoke-PSDepend -Force

    # Setting build script variables
    $script:moduleSourcePath = Join-Path -Path $BuildRoot -ChildPath $ModuleName
    $script:moduleManifestPath = Join-Path -Path $moduleSourcePath -ChildPath "$ModuleName.psd1"
    $script:nuspecPath = Join-Path -Path $moduleSourcePath -ChildPath "$ModuleName.nuspec"
    $script:buildOutputPath = Join-Path -Path $BuildRoot -ChildPath 'build'
    $script:Imports = ( 'private', 'public', 'classes' )

    # Setting base module version and using it if building locally
    $script:newModuleVersion = New-Object -TypeName 'System.Version' -ArgumentList (0, 0, 1)

    # Setting the list of functions ot be exported by module
    $script:functionsToExport = (Test-ModuleManifest $moduleManifestPath).ExportedFunctions
}

# Synopsis: Analyze the project with PSScriptAnalyzer
task Analyze {
    # Get-ChildItem parameters
    $Params = @{
        Path    = $moduleSourcePath
        Recurse = $true
        Include = "*.PSSATests.*"
    }

    $TestFiles = Get-ChildItem @Params

    # Pester parameters
    $Params = @{
        Path     = $TestFiles
        PassThru = $true
    }

    # Additional parameters on Azure Pipelines agents to generate test results
    if ($env:TF_BUILD) {
        if (-not (Test-Path -Path $buildOutputPath -ErrorAction SilentlyContinue)) {
            New-Item -Path $buildOutputPath -ItemType Directory
        }
        $Timestamp = Get-date -UFormat "%Y%m%d-%H%M%S"
        $PSVersion = $PSVersionTable.PSVersion.Major
        $TestResultFile = "AnalysisResults_PS$PSVersion`_$TimeStamp.xml"
        $Params.Add("OutputFile", "$buildOutputPath\$TestResultFile")
        $Params.Add("OutputFormat", "NUnitXml")
    }

    # Invoke all tests
    $TestResults = Invoke-Pester @Params
    if ($TestResults.FailedCount -gt 0) {
        $TestResults | Format-List
        throw "One or more PSScriptAnalyzer rules have been violated. Build cannot continue!"
    }
}

# Synopsis: Test the project with Pester tests
task Test {
    # Get-ChildItem parameters
    $Params = @{
        Path    = $moduleSourcePath
        Recurse = $true
        Include = "*.Tests.*"
    }

    $TestFiles = Get-ChildItem @Params

    # Pester parameters
    $Params = @{
        Path     = $TestFiles
        PassThru = $true
    }

    # Additional parameters on Azure Pipelines agents to generate test results
    if ($env:TF_BUILD) {
        if (-not (Test-Path -Path $buildOutputPath -ErrorAction SilentlyContinue)) {
            New-Item -Path $buildOutputPath -ItemType Directory
        }
        $Timestamp = Get-date -UFormat "%Y%m%d-%H%M%S"
        $PSVersion = $PSVersionTable.PSVersion.Major
        $TestResultFile = "TestResults_PS$PSVersion`_$TimeStamp.xml"
        $Params.Add("OutputFile", "$buildOutputPath\$TestResultFile")
        $Params.Add("OutputFormat", "NUnitXml")
    }

    # Invoke all tests
    $TestResults = Invoke-Pester @Params
    if ($TestResults.FailedCount -gt 0) {
        $TestResults | Format-List
        throw "One or more Pester tests have failed. Build cannot continue!"
    }
}

# Synopsis: Generate a new module version if creating a release build
task GenerateNewModuleVersion -If ($Configuration -eq 'Release') {
    # Using the current NuGet package version from the feed as a version base when building via Azure DevOps pipeline

    # Define package repository name
    $repositoryName = $ModuleName + '-repository'
    $feedUsername = $ADOPat
    # Create credentials
    $password = ConvertTo-SecureString -String $ADOPat -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($feedUsername, $password)

    # Register a target PSRepository
    try {

        Register-PackageSource -ProviderName 'PowerShellGet' -Name $repositoryName -Location $SourceLocation -Credential $Credential

    }
    catch {
        throw "Cannot register '$repositoryName' repository with source location '$SourceLocation'!"
    }

    # Define variable for existing package
    $existingPackage = $null

    try {
        # Look for the module package in the repository
        $existingPackage = Find-Module -Name $ModuleName -Credential $credential
    }
    # In no existing module package was found, the base module version defined in the script will be used
    catch {
        Write-Warning "No existing package for '$ModuleName' module was found in '$repositoryName' repository!"
    }

    # If existing module package was found, try to install the module
    if ($existingPackage) {
        # Get the largest module version
        # $currentModuleVersion = (Get-Module -Name $ModuleName -ListAvailable | Measure-Object -Property 'Version' -Maximum).Maximum
        $currentModuleVersion = New-Object -TypeName 'System.Version' -ArgumentList ($existingPackage.Version)

        # Set module version base numbers
        [int]$Major = $currentModuleVersion.Major
        [int]$Minor = $currentModuleVersion.Minor
        [int]$Build = $currentModuleVersion.Build

        try {
            # Install the existing module from the repository
            Install-Module -Name $ModuleName -RequiredVersion $existingPackage.Version -Credential $credential
        }
        catch {
            throw "Cannot import module '$ModuleName'!"
        }

        # Get the count of exported module functions
        $existingFunctionsCount = (Get-Command -Module $ModuleName | Where-Object -Property Version -EQ $existingPackage.Version | Measure-Object).Count
        # Check if new public functions were added in the current build
        [int]$sourceFunctionsCount = (Get-ChildItem -Path "$moduleSourcePath\Public\*.ps1" -Exclude "*.Tests.*" | Measure-Object).Count
        [int]$newFunctionsCount = [System.Math]::Abs($sourceFunctionsCount - $existingFunctionsCount)

        # Increase the minor number if any new public functions have been added
        if ($newFunctionsCount -gt 0) {
            [int]$Minor = $Minor + 1
            [int]$Build = 0
        }
        # If not, just increase the build number
        else {
            [int]$Build = $Build + 1
        }

        # Update the module version object
        $Script:newModuleVersion = New-Object -TypeName 'System.Version' -ArgumentList ($Major, $Minor, $Build)
    }
}

# Synopsis: Generate list of functions to be exported by module
task GenerateListOfFunctionsToExport {
    # Set exported functions by finding functions exported by *.psm1 file via Export-ModuleMember
    $params = @{
        Force    = $true
        Passthru = $true
        Name     = (Resolve-Path (Get-ChildItem -Path $moduleSourcePath -Filter '*.psm1')).Path
    }
    $PowerShell = [Powershell]::Create()
    [void]$PowerShell.AddScript(
        {
            Param ($Force, $Passthru, $Name)
            $module = Import-Module -Name $Name -PassThru:$Passthru -Force:$Force
            $module | Where-Object { $_.Path -notin $module.Scripts }
        }
    ).AddParameters($Params)
    $module = $PowerShell.Invoke()
    $Script:functionsToExport = $module.ExportedFunctions.Keys
}

# Synopsis: Update the module manifest with module version and functions to export
task UpdateModuleManifest GenerateNewModuleVersion, GenerateListOfFunctionsToExport, {
    # Update-ModuleManifest parameters
    $Params = @{
        Path              = $moduleManifestPath
        ModuleVersion     = $newModuleVersion
        FunctionsToExport = $functionsToExport
    }

    # Update the manifest file
    Update-ModuleManifest @Params
}

# Synopsis: Update the NuGet package specification with module version
task UpdatePackageSpecification GenerateNewModuleVersion, {
    # Load the specification into XML object
    $xml = New-Object -TypeName 'XML'
    $xml.Load($nuspecPath)

    # Update package version
    $metadata = Select-XML -Xml $xml -XPath '//package/metadata'
    $metadata.Node.Version = $newModuleVersion

    # Save XML object back to the specification file
    $xml.Save($nuspecPath)
}

# Synopsis: Build the project
task Build UpdateModuleManifest, UpdatePackageSpecification, {
    # Warning on local builds
    if ($Configuration -eq 'Debug') {
        Write-Warning "Creating a debug build. Use it for test purpose only!"
    }

    # Create versioned output folder
    $moduleOutputPath = Join-Path -Path $buildOutputPath -ChildPath $ModuleName -AdditionalChildPath $newModuleVersion
    if (-not (Test-Path $moduleOutputPath)) {
        New-Item -Path $moduleOutputPath -ItemType Directory
    }

    # Copy-Item parameters
    $Params = @{
        Path        = "$moduleSourcePath\*"
        Destination = $moduleOutputPath
        Exclude     = "*.Tests.*", "*.PSSATests.*"
        Recurse     = $true
        Force       = $true
    }

    # Copy module files to the target build folder
    Copy-Item @Params


    #Populating the PSM1 file
    [System.Text.StringBuilder]$stringbuilder = [System.Text.StringBuilder]::new()    
    foreach ($folder in $imports ) {
        [void]$stringbuilder.AppendLine( "Write-Verbose 'Importing from [$moduleSourcePath\$folder]'" )
        if (Test-Path "$moduleSourcePath\$folder") {
            $fileList = Get-ChildItem "$moduleSourcePath\$folder\*.ps1" | Where-Object Name -NotLike '*.Tests.ps1'
            foreach ($file in $fileList) {
                $shortName = $file.fullname.replace($PSScriptRoot, '')
                Write-Output -InputObject "  Importing [.$shortName]"
                [void]$stringbuilder.AppendLine( "# .$shortName" ) 
                [void]$stringbuilder.AppendLine( [System.IO.File]::ReadAllText($file.fullname) )
            }
        }
    }
    $script:ModulePath = Join-Path -Path $moduleOutputPath -ChildPath "$ModuleName.psm1"
    Write-Output -InputObject "  Creating module [$ModulePath]"
    Set-Content -Path  $ModulePath -Value $stringbuilder.ToString()

    #Cleaning up output folders
    foreach ($folder in $imports ) {
        if (Test-Path "$moduleOutputPath\$folder") {
            Write-Output -InputObject "  Removing [$moduleOutputPath\$folder]"
            Remove-Item –Path "$moduleOutputPath\$folder" –Recurse
        }
    }

}

# Synopsis: Verify the code coverage by tests
task CodeCoverage {

    $path = $moduleSourcePath
    $files = Get-ChildItem $path -Recurse -Include '*.ps1', '*.psm1' -Exclude '*.Tests.ps1', '*.PSSATests.ps1'

    $Params = @{
        Path         = $path
        CodeCoverage = $files
        PassThru     = $true
        Show         = 'Summary'
    }

    # Additional parameters on Azure Pipelines agents to generate code coverage report
    if ($env:TF_BUILD) {
        if (-not (Test-Path -Path $buildOutputPath -ErrorAction SilentlyContinue)) {
            New-Item -Path $buildOutputPath -ItemType Directory
        }
        $Timestamp = Get-date -UFormat "%Y%m%d-%H%M%S"
        $PSVersion = $PSVersionTable.PSVersion.Major
        $TestResultFile = "CodeCoverageResults_PS$PSVersion`_$TimeStamp.xml"
        $Params.Add("CodeCoverageOutputFile", "$buildOutputPath\$TestResultFile")

        Write-Output -InputObject "CodeCoverageOutputFile root path is : $buildOutputPath\$TestResultFile"
    }

    $result = Invoke-Pester @Params

    If ( $result.CodeCoverage ) {
        $codeCoverage = $result.CodeCoverage
        $commandsFound = $codeCoverage.NumberOfCommandsAnalyzed

        # To prevent any "Attempted to divide by zero" exceptions
        If ( $commandsFound -ne 0 ) {
            $commandsExercised = $codeCoverage.NumberOfCommandsExecuted
            [System.Double]$actualCodeCoveragePercent = [Math]::Round(($commandsExercised / $commandsFound) * 100, 2)
        }
        Else {
            [System.Double]$actualCodeCoveragePercent = 0
        }
    }

    # Fail the task if the code coverage results are not acceptable
    if ($actualCodeCoveragePercent -lt $acceptableCodeCoveragePercent) {
        throw "The overall code coverage by Pester tests is $actualCodeCoveragePercent% which is less than quality gate of $acceptableCodeCoveragePercent%. Pester ModuleVersion is: $((Get-Module -Name Pester -ListAvailable).Version)."
    }
}

# Synopsis: Creating the help files for the module
task BuildingHelpFiles {

    $path = $moduleSourcePath
    $Modules = get-childitem -path $path -recurse -Filter *.psd1 -Verbose

    Write-Output -InputObject "Modules: $Modules"

    foreach ($Module in $Modules) {

        #Remove the module from OS
        Write-Output -InputObject "Start processing the following module : $($Module.Name)"
        Get-Module $Module.Name | Uninstall-Module -Force -ErrorAction SilentlyContinue

        #Install module from repo
        Import-Module -Name $Module.FullName -Verbose

        #Retrieve version number of module
        $TempModule = Get-Module -ListAvailable $Module.FullName

        $ModuleVersion = $TempModule.Version.ToString()
        write-output -InputObject "$($Module.Name) has version : $ModuleVersion"

        #Construction file paths

        if (-not (Test-Path -Path $buildOutputPath -ErrorAction SilentlyContinue)) {
            New-Item -Path $buildOutputPath -ItemType Directory
        }

        $RootPath = "$buildOutputPath\Help"
        If (!(test-path $RootPath)) {
            New-Item -ItemType Directory -Force -Path $RootPath
        }

        $RootModulePath = "$RootPath\$($Module.BaseName)"
        If (!(test-path $RootModulePath)) {
            New-Item -ItemType Directory -Force -Path $RootModulePath
        }

        $Modulepath = "$RootModulePath\$ModuleVersion"
        If (test-path $Modulepath) {
            Remove-Item –path $Modulepath –recurse
        }
        New-Item -ItemType Directory -Force -Path $Modulepath

        #Constructing new markdown files
        $parameters = @{
            Module                = $Module.BaseName
            OutputFolder          = $Modulepath
            AlphabeticParamsOrder = $true
            WithModulePage        = $true
            ExcludeDontShow       = $true
            Force                 = $true
        }
        New-MarkdownHelp @parameters

        #Creating index files for module
        Copy-Item -Path "$Modulepath\$($Module.BaseName).md" -Destination "$Modulepath\index.md" -Force

        #Create New version specific Markdown file

        "---" |  Out-File -FilePath "$Modulepath\index.md" -Force
        "name : $ModuleVersion" |  Out-File -FilePath "$Modulepath\index.md" -Append -Force
        "order : 1000 # higher has more priority" |  Out-File -FilePath "$Modulepath\index.md" -Append -Force
        "---" |  Out-File -FilePath "$Modulepath\index.md" -Append -Force
        "" |  Out-File -FilePath "$Modulepath\index.md" -Append -Force
        "#PowerShell Module $ModuleVersion home page" |  Out-File -FilePath "$Modulepath\index.md" -Append -Force

        #Creating header for indexing services
        $Files = Get-ChildItem -Path $Modulepath -File -Recurse
        $Counter = 1

        Write-Output -InputObject "Start processing the MD files to include header."
        Foreach ($File in $Files) {
            [System.Collections.ArrayList]$files = Get-Content -Path $File.FullName

            ($files | Select-String -Pattern '----')
            $index = ($files.IndexOf('----') + 2)

            # Checking correct name, index is not correct
            if ($($File.BaseName) -eq "index") {
                $line1 = "Name : $($Module.Name)"
            }
            else {
                $line1 = "Name : $($File.BaseName)"
            }

            #Added counter for ordering the files
            $Order = $Counter * 100
            $line2 = "Order : $Order"
            $Counter ++

            #Writing files
            $insert = @($line1, $line2)
            $files.Insert($index, $insert)
            $files | Out-File $File.FullName

        }
    }
}

# Synopsis: Clean up the target build directory
task Clean {
    if (Test-Path $buildOutputPath) {
        Remove-Item –Path $buildOutputPath –Recurse
    }
}