#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$migrationScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Migrate-PowerBIReports.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("powerbi-migration-tests-" + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($testRoot)
$sourceId = '11111111-1111-1111-1111-111111111111'
$targetId = '22222222-2222-2222-2222-222222222222'
$datasetId = '33333333-3333-3333-3333-333333333333'
$reportId = '44444444-4444-4444-4444-444444444444'
$secondReportId = '55555555-5555-5555-5555-555555555555'
$capacityId = '66666666-6666-6666-6666-666666666666'
$global:mock = $null
$testCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $null
    try { $null = & $Action } catch { $caught = $_ }
    Assert-True ($null -ne $caught) "Expected error matching '$Pattern'."
    Assert-True ($caught.Exception.Message -match $Pattern) "Unexpected error: $($caught.Exception.Message)"
}

function Reset-Mock {
    $global:mock = @{
        groups = @(
            @{ id = $sourceId; name = 'Lama'; isReadOnly = $false; isOnDedicatedCapacity = $true; capacityId = $capacityId }
            @{ id = $targetId; name = 'Baru'; isReadOnly = $false; isOnDedicatedCapacity = $true; capacityId = $capacityId }
        )
        sourceReports = @(@{ id = $reportId; name = 'Sales'; datasetId = $datasetId; reportType = 'PowerBIReport' })
        targetReports = @()
        requests = [Collections.Generic.List[object]]::new()
        sleeps = [Collections.Generic.List[int]]::new()
        postCount = 0
        deleteCount = 0
        loginCount = 0
        tokenCount = 0
        failPost = $false
        failVerify = $false
        wrongBinding = $false
        throttleGets = 0
        throttlePost = $false
        failToken = $false
        failLogin = $false
        invalidToken = $false
        failVerifyAt = 0
        targetGetCount = 0
        failDelete = $false
        failDeleteAt = 0
        lostDeleteResponse = $false
        leaveSourceAfterDelete = $false
        mutateSourceOnGetId = $null
        forbidMissingSourceGet = $false
    }
}

function Connect-PowerBIServiceAccount {
    [CmdletBinding()]
    param([string]$Environment)
    Assert-True ($Environment -eq 'Public') 'Interactive user login uses Public cloud.'
    $global:mock['loginCount']++
    if ($global:mock['failLogin']) { throw 'Mock interactive login cancelled' }
    return [pscustomobject]@{ Environment = $Environment }
}

function Get-PowerBIAccessToken {
    [CmdletBinding()]
    param()
    $global:mock['tokenCount']++
    if ($global:mock['failToken']) { throw 'Mock Gagal mendapatkan token' }
    if ($global:mock['invalidToken']) { return @{ Authorization = 'invalid-token' } }
    return @{ Authorization = 'Bearer mock-token-not-a-secret' }
}

function Start-Sleep {
    param([int]$Seconds)
    $global:mock['sleeps'].Add($Seconds)
}

function Invoke-WebRequest {
    param($Uri, $Method, $Headers, $Body, $ContentType, $TimeoutSec, $MaximumRedirection, [switch]$SkipHttpErrorCheck)
    Assert-True ($Uri.StartsWith('https://api.powerbi.com/v1.0/myorg/')) 'Unexpected API host.'
    Assert-True ($Headers.Authorization -eq 'Bearer mock-token-not-a-secret') 'Unexpected token.'
    $path = $Uri.Substring('https://api.powerbi.com/v1.0/myorg/'.Length)
    $global:mock['requests'].Add(@{ method = $Method; path = $path; body = $Body })
    $status = 200
    $responseHeaders = @{}
    $data = $null
    if ($Method -eq 'GET' -and $global:mock['throttleGets'] -gt 0) {
        $global:mock['throttleGets']--
        $status = 429
        $responseHeaders['Retry-After'] = @('7')
        $data = @{ error = @{ code = 'TooManyRequests' } }
    } elseif ($path -match '^groups\?\$top=100&\$skip=(\d+)$') {
        $data = @{ value = @($global:mock['groups'] | Select-Object -Skip ([int]$Matches[1]) -First 100) }
    } elseif ($path -eq "groups/$sourceId/reports") {
        $data = @{ value = $global:mock['sourceReports'] }
    } elseif ($path -eq "groups/$targetId/reports") {
        $data = @{ value = $global:mock['targetReports'] }
    } elseif ($Method -eq 'POST' -and $path -match '^groups/([^/]+)/reports/([^/]+)/Clone$') {
        $global:mock['postCount']++
        Assert-True ($Matches[1] -eq $sourceId) 'Clone must use source workspace.'
        $sourceReport = @($global:mock['sourceReports'] | Where-Object { $_['id'] -eq $Matches[2] })[0]
        $payload = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json -AsHashtable
        Assert-True ($payload['targetWorkspaceId'] -eq $targetId) 'Clone targetWorkspaceId mismatch.'
        Assert-True (-not $payload.ContainsKey('targetModelId')) 'Clone must keep original semantic model.'
        Assert-True ($payload['name'] -ceq $sourceReport['name']) 'Clone report name mismatch.'
        if ($global:mock['throttlePost']) {
            return [pscustomobject]@{ StatusCode = 429; Content = '{"error":{"code":"TooManyRequests"}}'; Headers = @{ 'Retry-After' = @('7') } }
        }
        $newId = [guid]::NewGuid().ToString()
        $data = @{
            id = $newId
            name = $payload['name']
            datasetId = $sourceReport['datasetId']
            webUrl = "https://app.powerbi.com/groups/$targetId/reports/$newId"
        }
        $global:mock['targetReports'] += $data
        if ($global:mock['failPost']) { throw [TimeoutException]::new('Mock lost POST response') }
    } elseif ($Method -eq 'GET' -and $path -match "^groups/$targetId/reports/([^/]+)$") {
        $global:mock['targetGetCount']++
        if ($global:mock['failVerify'] -or $global:mock['targetGetCount'] -eq $global:mock['failVerifyAt']) {
            return [pscustomobject]@{ StatusCode = 403; Content = '{"error":{"code":"Forbidden"}}'; Headers = @{} }
        }
        $found = @($global:mock['targetReports'] | Where-Object { $_['id'] -eq $Matches[1] })
        Assert-True ($found.Count -eq 1) 'Target GET must use created report ID.'
        $data = $found[0].Clone()
        if ($global:mock['wrongBinding']) { $data['datasetId'] = $secondReportId }
    } elseif ($path -match "^groups/$sourceId/reports/([^/]+)$") {
        $id = $Matches[1]
        if ($Method -eq 'DELETE') {
            $global:mock['deleteCount']++
            if ($global:mock['failDelete'] -or $global:mock['deleteCount'] -eq $global:mock['failDeleteAt']) {
                return [pscustomobject]@{ StatusCode = 403; Content = '{"error":{"code":"Forbidden"}}'; Headers = @{} }
            }
            if (-not $global:mock['leaveSourceAfterDelete']) {
                $global:mock['sourceReports'] = @($global:mock['sourceReports'] | Where-Object { $_['id'] -ne $id })
            }
            if ($global:mock['lostDeleteResponse']) { throw [TimeoutException]::new('Mock lost DELETE response') }
            return [pscustomobject]@{ StatusCode = 200; Content = ''; Headers = @{} }
        }
        Assert-True ($Method -eq 'GET') 'Only GET/DELETE supported for source report.'
        $found = @($global:mock['sourceReports'] | Where-Object { $_['id'] -eq $id })
        if ($found.Count -eq 0) {
            $missingStatus = if ($global:mock['forbidMissingSourceGet']) { 403 } else { 404 }
            return [pscustomobject]@{ StatusCode = $missingStatus; Content = '{"error":{"code":"MissingOrForbidden"}}'; Headers = @{} }
        }
        $data = $found[0].Clone()
        if ($id -eq $global:mock['mutateSourceOnGetId']) { $data['datasetId'] = $capacityId }
    } else {
        throw "Unexpected request: $Method $path"
    }
    return [pscustomobject]@{ StatusCode = $status; Content = ($data | ConvertTo-Json -Depth 20 -Compress); Headers = $responseHeaders }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    Reset-Mock
    $statePath = Join-Path $testRoot "$Name.json"
    $parameters = @{ SourceWorkspace = 'Lama'; TargetWorkspace = 'Baru'; StatePath = $statePath }
    & $Body
    $script:testCount++
    Write-Host "PASS: $Name"
}

try {
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($migrationScript, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) ($parseErrors | Out-String)

    Test-Case 'preview-no-writes' {
        $result = @(& $migrationScript @parameters)
        Assert-True ($result.Count -eq 1 -and $result[0].action -eq 'Clone') 'Preview plan shape.'
        Assert-True ($global:mock['postCount'] -eq 0) 'Preview cannot POST.'
        Assert-True ($global:mock['deleteCount'] -eq 0) 'Preview cannot DELETE.'
        Assert-True (-not (Test-Path -LiteralPath $statePath)) 'Preview cannot save state.'
    }
    Test-Case 'clone-and-resume' {
        $result = @(& $migrationScript @parameters -Apply)
        Assert-True ($result.Count -eq 1 -and $result[0].status -eq 'Verified') 'Clone result shape.'
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($saved['reports'][$reportId]['targetReportId'] -eq $result[0].targetReportId) 'Persistent source-target mapping.'
        Assert-True (-not (Get-Content -LiteralPath $statePath -Raw).Contains('mock-token')) 'State cannot contain token.'
        Assert-True (-not (Test-Path -LiteralPath "$statePath.tmp")) 'Temporary state cleaned up.'
        $null = & $migrationScript @parameters -Apply
        Assert-True ($global:mock['postCount'] -eq 1) 'Resume cannot create another copy.'
        Assert-True ($global:mock['deleteCount'] -eq 0 -and $global:mock['sourceReports'].Count -eq 1) 'Default Copy must retain source.'
        Assert-True ($global:mock['loginCount'] -eq 2) 'Each invocation uses interactive user login.'
        Assert-True ($global:mock['tokenCount'] -eq $global:mock['requests'].Count) 'Retrieve session headers before each request.'
    }
    Test-Case 'same-workspace' {
        $parameters['TargetWorkspace'] = 'Lama'
        Assert-Throws { & $migrationScript @parameters -Apply } 'harus berbeda'
        Assert-True ($global:mock['postCount'] -eq 0) 'Same workspace blocked.'
    }
    Test-Case 'different-capacity' {
        $global:mock['groups'][1]['capacityId'] = $secondReportId
        Assert-Throws { & $migrationScript @parameters -Apply } 'capacityId.*berbeda'
        Assert-True ($global:mock['postCount'] -eq 0) 'Capacity mismatch blocked.'
    }
    Test-Case 'missing-capacity' {
        $global:mock['groups'][1].Remove('capacityId')
        Assert-Throws { & $migrationScript @parameters -Apply } 'capacityId dedicated'
    }
    Test-Case 'readonly-workspace' {
        $global:mock['groups'][1]['isReadOnly'] = $true
        Assert-Throws { & $migrationScript @parameters -Apply } 'akses tulis'
    }
    Test-Case 'preflight-all-conflicts' {
        $global:mock['sourceReports'] += @{ id = $secondReportId; name = 'Other'; datasetId = $datasetId }
        $global:mock['targetReports'] = @(@{ id = [guid]::NewGuid().ToString(); name = 'Other'; datasetId = $datasetId })
        Assert-Throws { & $migrationScript @parameters -Apply } 'sudah ada di tujuan'
        Assert-True ($global:mock['postCount'] -eq 0) 'Later conflict must prevent earlier clone.'
    }
    Test-Case 'report-selection-and-id-resolution' {
        $global:mock['sourceReports'] += @{ id = $secondReportId; name = 'Other'; datasetId = $datasetId }
        $parameters['SourceWorkspace'] = $sourceId
        $parameters['TargetWorkspace'] = $targetId
        $result = @(& $migrationScript @parameters -ReportIds $secondReportId -Apply)
        Assert-True ($result.Count -eq 1 -and $result[0].name -eq 'Other') 'Select exact report ID.'
        Assert-True ($global:mock['postCount'] -eq 1) 'Only selected report cloned.'
    }
    Test-Case 'missing-report-id' {
        Assert-Throws { & $migrationScript @parameters -ReportIds $secondReportId -Apply } 'tidak ditemukan'
        Assert-True ($global:mock['postCount'] -eq 0) 'Unknown ID blocked.'
    }
    Test-Case 'unsupported-report' {
        $global:mock['sourceReports'][0] = @{ id = $reportId; name = 'Invoice'; reportType = 'PaginatedReport' }
        Assert-Throws { & $migrationScript @parameters -Apply } 'tidak didukung'
    }
    Test-Case 'duplicate-source-name' {
        $global:mock['sourceReports'] += @{ id = $secondReportId; name = 'Sales'; datasetId = $datasetId }
        Assert-Throws { & $migrationScript @parameters -Apply } 'nama sama'
    }
    Test-Case 'ambiguous-workspace-name' {
        $global:mock['groups'] += @{ id = $secondReportId; name = 'Lama' }
        Assert-Throws { & $migrationScript @parameters -Apply } 'ditemukan 2 kali'
    }
    Test-Case 'pagination' {
        $global:mock['groups'] = @(
            1..100 | ForEach-Object { @{ id = [guid]::NewGuid().ToString(); name = "Unrelated $_" } }
        ) + $global:mock['groups']
        $null = & $migrationScript @parameters
        Assert-True (@($global:mock['requests'] | Where-Object { $_['path'] -match '^groups\?' }).Count -eq 2) 'Workspace pagination.'
    }
    Test-Case 'lost-post-not-replayed' {
        $global:mock['failPost'] = $true
        Assert-Throws { & $migrationScript @parameters -Apply } 'lost POST'
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($saved['reports'][$reportId]['status'] -eq 'CloneRequested') 'Uncertain clone recorded.'
        $global:mock['failPost'] = $false
        Assert-Throws { & $migrationScript @parameters -Apply } 'belum pasti'
        Assert-True ($global:mock['postCount'] -eq 1 -and $global:mock['targetReports'].Count -eq 1) 'Lost response cannot duplicate report.'
    }
    Test-Case 'verify-failure-resume' {
        $global:mock['failVerify'] = $true
        Assert-Throws { & $migrationScript @parameters -Apply } 'HTTP 403'
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($saved['reports'][$reportId]['status'] -eq 'Created') 'Created ID saved before GET.'
        $global:mock['failVerify'] = $false
        $null = & $migrationScript @parameters -Apply
        Assert-True ($global:mock['postCount'] -eq 1) 'Verification retry cannot clone again.'
    }
    Test-Case 'wrong-dataset-binding' {
        $global:mock['wrongBinding'] = $true
        Assert-Throws { & $migrationScript @parameters -Apply } 'datasetId berbeda'
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($saved['reports'][$reportId]['status'] -eq 'Created') 'Wrong binding cannot be marked Verified.'
    }
    Test-Case 'get-retry-after' {
        $global:mock['throttleGets'] = 1
        $null = & $migrationScript @parameters
        Assert-True ($global:mock['sleeps'].Count -eq 1 -and $global:mock['sleeps'][0] -eq 7) 'Respect Retry-After.'
    }
    Test-Case 'post-throttle-not-replayed' {
        $global:mock['throttlePost'] = $true
        Assert-Throws { & $migrationScript @parameters -Apply } 'HTTP 429'
        Assert-True ($global:mock['postCount'] -eq 1 -and $global:mock['sleeps'].Count -eq 0) 'No POST retry.'
    }
    Test-Case 'get-retry-limit' {
        $global:mock['throttleGets'] = 5
        Assert-Throws { & $migrationScript @parameters } 'HTTP 429'
        Assert-True ($global:mock['requests'].Count -eq 4 -and $global:mock['sleeps'].Count -eq 3) 'GET retries bounded.'
    }
    Test-Case 'wrong-state-workspace' {
        $null = & $migrationScript @parameters -Apply
        $global:mock['groups'] += @{ id = $secondReportId; name = 'Another'; isReadOnly = $false; isOnDedicatedCapacity = $true; capacityId = $capacityId }
        $parameters['TargetWorkspace'] = 'Another'
        Assert-Throws { & $migrationScript @parameters -Apply } 'State tidak cocok'
        Assert-True ($global:mock['postCount'] -eq 1) 'State cannot be reused with another target.'
    }
    Test-Case 'source-model-changed' {
        $null = & $migrationScript @parameters -Apply
        $global:mock['sourceReports'][0]['datasetId'] = $secondReportId
        Assert-Throws { & $migrationScript @parameters -Apply } 'berubah sejak'
        Assert-True ($global:mock['postCount'] -eq 1) 'Source rebinding requires review.'
    }
    Test-Case 'target-model-changed' {
        $null = & $migrationScript @parameters -Apply
        $global:mock['targetReports'][0]['datasetId'] = $secondReportId
        Assert-Throws { & $migrationScript @parameters -Apply } 'datasetId berbeda'
        Assert-True ($global:mock['postCount'] -eq 1) 'Target rebinding cannot silently reuse.'
    }
    Test-Case 'same-state-lock' {
        $heldLock = [IO.File]::Open("$statePath.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            Assert-Throws { & $migrationScript @parameters -Apply } 'being used by another process'
            Assert-True ($global:mock['requests'].Count -eq 0) 'Concurrent Apply blocked before API requests.'
        } finally {
            $heldLock.Dispose()
        }
        $null = & $migrationScript @parameters -Apply
        Assert-True ($global:mock['postCount'] -eq 1) 'Released lock permits migration.'
    }
    Test-Case 'token-failure' {
        $global:mock['failToken'] = $true
        Assert-Throws { & $migrationScript @parameters } 'Gagal mendapatkan token'
        Assert-True ($global:mock['requests'].Count -eq 0) 'Auth failure must stop before HTTP.'
    }
    Test-Case 'interactive-login-cancelled' {
        $global:mock['failLogin'] = $true
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'login cancelled'
        Assert-True ($global:mock['requests'].Count -eq 0 -and $global:mock['tokenCount'] -eq 0) 'Cancelled login must stop before tokens/API.'
    }
    Test-Case 'invalid-authentication-header' {
        $global:mock['invalidToken'] = $true
        Assert-Throws { & $migrationScript @parameters } 'Respons token sesi Power BI tidak valid'
        Assert-True ($global:mock['requests'].Count -eq 0) 'Invalid header cannot reach API.'
    }
    Test-Case 'move-preview-no-writes' {
        $result = @(& $migrationScript @parameters -Mode Move)
        Assert-True ($result[0].sourceAction -eq 'Delete') 'Move preview states source will be deleted.'
        Assert-True ($global:mock['postCount'] -eq 0 -and $global:mock['deleteCount'] -eq 0) 'Move preview read-only.'
        Assert-True (-not (Test-Path -LiteralPath $statePath)) 'Move preview cannot save state.'
    }
    Test-Case 'move-all-and-resume' {
        $global:mock['sourceReports'] += @{ id = $secondReportId; name = 'Other'; datasetId = $datasetId }
        $result = @(& $migrationScript @parameters -Mode Move -Apply)
        Assert-True ($result.Count -eq 2 -and @($result | Where-Object status -ne 'SourceDeleted').Count -eq 0) 'Move result status and count.'
        Assert-True ($global:mock['sourceReports'].Count -eq 0 -and $global:mock['targetReports'].Count -eq 2) 'Move retains targets and removes selected sources.'
        $firstDelete = $global:mock['requests'].FindIndex([Predicate[object]]{ param($request) $request['method'] -eq 'DELETE' })
        $beforeDelete = @($global:mock['requests'] | Select-Object -First $firstDelete)
        Assert-True (@($beforeDelete | Where-Object { $_['method'] -eq 'POST' }).Count -eq 2) 'All clones before first DELETE.'
        Assert-True (@($beforeDelete | Where-Object { $_['method'] -eq 'GET' -and $_['path'] -match "^groups/$targetId/reports/.+" }).Count -eq 2) 'All targets verified before first DELETE.'
        Assert-True (@($beforeDelete | Where-Object { $_['method'] -eq 'GET' -and $_['path'] -match "^groups/$sourceId/reports/.+" }).Count -eq 2) 'All sources rechecked before first DELETE.'
        $null = & $migrationScript @parameters -Mode Move -ReportIds $reportId, $secondReportId -Apply
        Assert-True ($global:mock['postCount'] -eq 2 -and $global:mock['deleteCount'] -eq 2) 'Completed Move resumes without clone or DELETE replay.'
    }
    Test-Case 'move-selected-only' {
        $global:mock['sourceReports'] += @{ id = $secondReportId; name = 'Other'; datasetId = $datasetId }
        $null = & $migrationScript @parameters -Mode Move -ReportIds $secondReportId -Apply
        Assert-True ($global:mock['sourceReports'].Count -eq 1 -and $global:mock['sourceReports'][0]['id'] -eq $reportId) 'Unselected source preserved.'
        Assert-True ($global:mock['postCount'] -eq 1 -and $global:mock['deleteCount'] -eq 1) 'Only selected report moved.'
    }
    Test-Case 'move-last-target-fails-no-delete' {
        $global:mock['sourceReports'] += @{ id = $secondReportId; name = 'Other'; datasetId = $datasetId }
        $global:mock['failVerifyAt'] = 2
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'HTTP 403'
        Assert-True ($global:mock['deleteCount'] -eq 0 -and $global:mock['sourceReports'].Count -eq 2) 'No source deleted when later target fails.'
    }
    Test-Case 'move-source-changed-no-delete' {
        $global:mock['sourceReports'] += @{ id = $secondReportId; name = 'Other'; datasetId = $datasetId }
        $global:mock['mutateSourceOnGetId'] = $secondReportId
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'datasetId berbeda'
        Assert-True ($global:mock['deleteCount'] -eq 0 -and $global:mock['sourceReports'].Count -eq 2) 'No source deleted when later source changed.'
    }
    Test-Case 'copy-then-move-reuses-target' {
        $null = & $migrationScript @parameters -Mode Copy -Apply
        $result = @(& $migrationScript @parameters -Mode Move -Apply)
        Assert-True ($global:mock['postCount'] -eq 1 -and $global:mock['deleteCount'] -eq 1) 'Move after Copy reuses existing tracked target.'
        Assert-True ($result[0].status -eq 'SourceDeleted') 'Move after Copy completes.'
    }
    Test-Case 'move-delete-failure-and-resume' {
        $global:mock['failDelete'] = $true
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'HTTP 403'
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($saved['reports'][$reportId]['status'] -eq 'DeleteRequested') 'Failed deletion remains pending.'
        Assert-True ($global:mock['sourceReports'].Count -eq 1 -and $global:mock['deleteCount'] -eq 1) 'No automatic DELETE retry.'
        Assert-Throws { & $migrationScript @parameters -Mode Copy -Apply } 'Gunakan -Mode Move'
        Assert-True ($global:mock['deleteCount'] -eq 1) 'Copy cannot continue pending deletion.'
        $global:mock['failDelete'] = $false
        $null = & $migrationScript @parameters -Mode Move -Apply
        Assert-True ($global:mock['postCount'] -eq 1 -and $global:mock['sourceReports'].Count -eq 0) 'Explicit Move retry reuses clone.'
    }
    Test-Case 'lost-delete-response-resume' {
        $global:mock['lostDeleteResponse'] = $true
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'lost DELETE'
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($saved['reports'][$reportId]['status'] -eq 'DeleteRequested') 'Unknown DELETE response recorded.'
        $global:mock['lostDeleteResponse'] = $false
        $result = @(& $migrationScript @parameters -Mode Move -ReportIds $reportId -Apply)
        Assert-True ($result[0].status -eq 'SourceDeleted') 'Missing source confirmed after lost response.'
        Assert-True ($global:mock['postCount'] -eq 1 -and $global:mock['deleteCount'] -eq 1) 'No replay when source already absent.'
    }
    Test-Case 'move-delete-not-confirmed' {
        $global:mock['leaveSourceAfterDelete'] = $true
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'belum terkonfirmasi'
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($saved['reports'][$reportId]['status'] -eq 'DeleteRequested') 'DELETE 200 is insufficient without source absence.'
    }
    Test-Case 'move-forbidden-is-not-absence' {
        $global:mock['forbidMissingSourceGet'] = $true
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'HTTP 403'
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($saved['reports'][$reportId]['status'] -eq 'DeleteRequested') 'HTTP 403 cannot confirm absence.'
    }
    Test-Case 'move-pending-target-missing' {
        $global:mock['failDelete'] = $true
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'HTTP 403'
        $global:mock['failDelete'] = $false
        $global:mock['targetReports'] = @()
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'hilang atau konflik'
        Assert-True ($global:mock['deleteCount'] -eq 1 -and $global:mock['sourceReports'].Count -eq 1) 'Missing target blocks pending deletion.'
    }
    Test-Case 'move-partial-deletion-resume' {
        $global:mock['sourceReports'] += @{ id = $secondReportId; name = 'Other'; datasetId = $datasetId }
        $global:mock['failDeleteAt'] = 2
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'HTTP 403'
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($saved['reports'][$reportId]['status'] -eq 'SourceDeleted') 'First deletion remains recorded.'
        Assert-True ($saved['reports'][$secondReportId]['status'] -eq 'DeleteRequested') 'Later failed deletion remains pending.'
        $global:mock['failDeleteAt'] = 0
        $result = @(& $migrationScript @parameters -Mode Move -Apply)
        Assert-True ($result.Count -eq 2 -and @($result | Where-Object status -ne 'SourceDeleted').Count -eq 0) 'Partial Move resume completes both records.'
        Assert-True ($global:mock['postCount'] -eq 2 -and $global:mock['deleteCount'] -eq 3) 'Only the remaining source retried.'
    }
    Test-Case 'move-restored-source-requires-review' {
        $null = & $migrationScript @parameters -Mode Move -Apply
        $global:mock['sourceReports'] = @(@{ id = $reportId; name = 'Sales'; datasetId = $datasetId; reportType = 'PowerBIReport' })
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'muncul lagi setelah SourceDeleted'
        Assert-True ($global:mock['deleteCount'] -eq 1) 'Restored source not deleted again.'
    }
    Write-Host "All $testCount tests passed. No live API was called."
} finally {
    Remove-Variable -Name mock -Scope Global
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
