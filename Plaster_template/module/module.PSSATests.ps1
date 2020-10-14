$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$modulePath = $here
$moduleName = Split-Path -Path $modulePath -Leaf

Describe "'$moduleName' Module Analysis with PSScriptAnalyzer" {
    Context 'Standard Rules' {
        # Define PSScriptAnalyzer rules
        $scriptAnalyzerRules = Get-ScriptAnalyzerRule # Just getting all default rules

        # Perform analysis against each rule
        forEach ($rule in $scriptAnalyzerRules) {
            It "should pass '$rule' rule" {
                Invoke-ScriptAnalyzer -Path "$here\$moduleName.psm1" -IncludeRule $rule | Should -BeNullOrEmpty
            }
        }
    }
}

# Dynamically defining the functions to analyze
$functionPaths = @()
if (Test-Path -Path "$modulePath\Private\*.ps1") {
    $functionPaths += Get-ChildItem -Path "$modulePath\Private\*.ps1" -Exclude "*.Tests.*"
}
if (Test-Path -Path "$modulePath\Public\*.ps1") {
    $functionPaths += Get-ChildItem -Path "$modulePath\Public\*.ps1" -Exclude "*.Tests.*"
}


#setup analyzer ignore rules
$scriptAnalyzerRulesIgnore = $null
$AnalyzerFile = Get-ChildItem -Path $modulePath -Include AnalyzerRulesIgnore.csv -File -Recurse -ErrorAction SilentlyContinue
If ($AnalyzerFile) {

    #Setting exclusion rules for PS Script analyzer
    $scriptAnalyzerRulesIgnore = Get-Content -Path $AnalyzerFile[0].FullName
}

# Running the analysis for each function
foreach ($functionPath in $functionPaths) {
    $functionName = $functionPath.BaseName

    Describe "'$functionName' Function Analysis with PSScriptAnalyzer" {
        Context 'Standard Rules' {
            # Define PSScriptAnalyzer rules

            $scriptAnalyzerRules = Get-ScriptAnalyzerRule # Just getting all default rules

            # Perform analysis against each rule
            forEach ($rule in $scriptAnalyzerRules) {
                if (!($scriptAnalyzerRulesIgnore -contains $($rule.RuleName))) {
                    It "should pass '$rule' rule" {
                        $results = Invoke-ScriptAnalyzer -Path $functionPath -IncludeRule $rule 
                        $results = $results | Out-String                    
                        $results | should BeNullOrEmpty
                    }
                }
                else {
                    Write-Warning -Message "The $rule is ignored for file $functionPath"
                }
            }
        }
    }
}