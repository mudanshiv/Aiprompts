# ===================== CONFIG ======================
$org = "test"         # Example: myorg
$project = "test" # Example: SampleProject
$pat = "test"              # Azure DevOps PAT Token
# ====================================================

$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$headers = @{ Authorization = "Basic $base64AuthInfo" }

$now = Get-Date
$last24 = $now.AddHours(-24)

Write-Host "Fetching latest releases executed in last 24 hours..." -ForegroundColor Yellow

# Fetch releases with environments
$releaseUrl = "https://vsrm.dev.azure.com/$org/$project/_apis/release/releases?`$expand=environments&queryOrder=descending&api-version=7.1-preview.8"
$allReleases = (Invoke-RestMethod -Uri $releaseUrl -Headers $headers -Method Get).value

# Pick only latest per definition + last 24 hours
$latestReleases = $allReleases |
    Where-Object { ([datetime]$_.createdOn) -ge $last24 } |
    Group-Object -Property { $_.releaseDefinition.id } |
    ForEach-Object { $_.Group | Sort-Object createdOn -Descending | Select-Object -First 1 }

$results = @()

foreach ($release in $latestReleases) {

    $releaseId = $release.id
    $releaseName = $release.name
    Write-Host "`nProcessing Release: $releaseName ($releaseId)" -ForegroundColor Cyan

    foreach ($env in $release.environments) {

        $stageName = $env.name
        $envId = $env.id
        $StageReleaseStatus= $env.status

        Write-Host " ➜ Stage: $stageName" -ForegroundColor Blue

        # Fetch test runs for this stage
        # $runUrl = "https://dev.azure.com/$org/$project/_apis/test/runs?releaseId=$releaseId&releaseEnvId=$envId&api-version=7.1-preview.5"
        $runUrl = "https://vstmr.dev.azure.com/$org/$project/_apis/testresults/resultsummarybyrelease?releaseId=$releaseId&releaseEnvId=$envId&api-version=7.1-preview.1"
        #$runUrl = "GET https://vstmr.dev.azure.com/{organization}/{project}/_apis/testresults/resultsummarybyrelease?releaseId={releaseId}&releaseEnvId={releaseEnvId}&api-version=7.1-preview.1"
        $runData = Invoke-RestMethod -Uri $runUrl -Headers $headers -Method Get

        if ($runData.aggregatedResultsAnalysis.totalTests -eq 0) {
            Write-Host "    No tests executed for stage" -ForegroundColor DarkGray

            $results += [PSCustomObject]@{
                PipelineName = $release.releaseDefinition.name
                ReleaseName  = $releaseName
                StageName    = $stageName
                StageReleaseStatus    = $StageReleaseStatus
                TotalTests   = 0
                Passed       = 0
                Failed       = 0
                Other        = 0
                TestrunSummaryByOutcome       = "NA"
                ReleaseDate  = $release.createdOn
            }
            continue
        }

        # Take latest test run
        #$testRun = $runData.value | Sort-Object completedDate -Descending | Select-Object -First 1
        #$runId = $testRun.id
        #Write-Host "    Test Run: $runId" -ForegroundColor Green

        # Fetch result summary
        #$resultsUrl = "https://dev.azure.com/$org/$project/_apis/test/runs/$runId/results?api-version=7.1-preview.6"
        #$resultsUrl = "https://vstmr.dev.azure.com/$org/$project/_apis/testresults/resultsbyrelease?releaseId=$releaseId&api-version=7.1-preview.1"
        #$testResults = (Invoke-RestMethod -Uri $resultsUrl -Headers $headers -Method Get).value

        $testResults = $runData.aggregatedResultsAnalysis.resultsByOutcome

        #$passed = ($testResults | Where-Object { $_.Passed.outcome -eq "passed" }).Count
        #$failed = ($testResults | Where-Object { $_.Failed.outcome -eq "failed" }).Count
        $passed = $testResults.Passed.count
        $failed = $testResults.Failed.count
        $total  = $runData.aggregatedResultsAnalysis.totalTests
        $other  = $total - ($passed + $failed)
        #$total  = $testResults.Count
        $runSummaryByOutcome = $runData.aggregatedResultsAnalysis.runSummaryByOutcome.psobject.Properties.Value.outcome

        $status = if ($failed -gt 0) { "Failed" } elseif ($total -eq 0) { "No Tests" } else { "Passed" }

        $results += [PSCustomObject]@{
            PipelineName = $release.releaseDefinition.name
            ReleaseName  = $releaseName
            StageName    = $stageName
            StageReleaseStatus    = $StageReleaseStatus
            TotalTests   = $total
            Passed       = $passed
            Failed       = $failed
            Other        = $other
            TestrunSummaryByOutcome       = $runSummaryByOutcome
            ReleaseDate  = $release.createdOn
        }
    }
}

# Export CSV Report
$timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$csvPath = "Release_Stage_Test_Summary_$timestamp.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation

Write-Host "`n======== Report Generated Successfully! ========" -ForegroundColor Green
Write-Host "CSV File: $csvPath" -ForegroundColor Green
