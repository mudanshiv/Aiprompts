# ================= Configuration =================
$org = "test"          # DevOps Org Name
$project = "test"    # DevOps Project Name
$pat = "test"            # Personal Access Token



$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$headers = @{ Authorization = "Basic $base64AuthInfo" }

$now = Get-Date
$last24 = $now.AddHours(-340)

Write-Host "Fetching latest release pipelines executed in last 24 hours..."

# Get releases ordered by latest
$releaseUrl = "https://vsrm.dev.azure.com/$org/$project/_apis/release/releases?`$expand=environments&queryOrder=descending&api-version=7.1-preview.8"
$allReleases = (Invoke-RestMethod -Uri $releaseUrl -Headers $headers -Method Get).value

# Filter releases within last 24 hours and group by pipeline (definition), pick only freshest
$latestReleases = $allReleases |
    Where-Object { ([datetime]$_.createdOn) -ge $last24 } |
    Group-Object -Property { $_.releaseDefinition.id } |
    ForEach-Object { $_.Group | Sort-Object createdOn -Descending | Select-Object -First 1 }

$results = @()

foreach ($release in $latestReleases)
{
    $releaseId = $release.id
    $releaseName = $release.name

    Write-Host "Processing latest release: $releaseName ($releaseId)"

    # Fetch test results for this release
    $testUrl = "https://dev.azure.com/$org/$project/_apis/test/Results?releaseId=$releaseId&api-version=7.1-preview.6"
    $testResults = (Invoke-RestMethod -Uri $testUrl -Headers $headers -Method Get).value

    if ($testResults.Count -eq 0) {
        Write-Host "No test results found -> Marking as No Test Results"

        $summary = [PSCustomObject]@{
            PipelineName     = $release.releaseDefinition.name
            ReleaseName      = $releaseName
            P1_Passed        = 0
            P1_Failed        = 0
            P2_Passed        = 0
            P2_Failed        = 0
            Status           = "No Test Results"
            ReleaseStartedOn = $release.createdOn
        }

        $results += $summary
        continue
    }

    # Filter priorities
    $p1Tests = $testResults | Where-Object { $_.priority -eq 1 }
    $p2Tests = $testResults | Where-Object { $_.priority -eq 2 }

    # Determine status
    $status = "Passed"
    if (($p1Tests | Where-Object { $_.outcome -eq "Failed" }).Count -gt 0 -or
        ($p2Tests | Where-Object { $_.outcome -eq "Failed" }).Count -gt 0) {
        $status = "Failed"
    }

    $summary = [PSCustomObject]@{
        PipelineName     = $release.releaseDefinition.name
        ReleaseName      = $releaseName
        P1_Passed        = ($p1Tests | Where-Object { $_.outcome -eq "Passed" }).Count
        P1_Failed        = ($p1Tests | Where-Object { $_.outcome -eq "Failed" }).Count
        P2_Passed        = ($p2Tests | Where-Object { $_.outcome -eq "Passed" }).Count
        P2_Failed        = ($p2Tests | Where-Object { $_.outcome -eq "Failed" }).Count
        Status           = $status
        ReleaseStartedOn = $release.createdOn
    }

    $results += $summary
}

$timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")

# Export to CSV
$csvPath = "Release_Test_Results_Latest_$timestamp.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation

Write-Host "Report generated successfully: $csvPath"

