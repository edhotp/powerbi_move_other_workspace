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
$failures = [Collections.Generic.List[string]]::new()

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

function New-ArchiveFixture {
    param([string]$EntryName = 'Report/Layout')
    $stream = [IO.MemoryStream]::new()
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            $writer = [IO.StreamWriter]::new($archive.CreateEntry($EntryName).Open())
            try { $writer.Write('mock report backup payload') } finally { $writer.Dispose() }
        } finally {
            $archive.Dispose()
        }
        return ,$stream.ToArray()
    } finally {
        $stream.Dispose()
    }
}

function Set-ResponseSequence {
    param([string]$Method, [string]$Path, [object[]]$Responses)
    $queue = [Collections.Generic.Queue[object]]::new()
    foreach ($response in $Responses) { $queue.Enqueue($response) }
    $global:mock['responseOverrides']["$Method $Path"] = $queue
}

function New-MockResponse {
    param([int]$Status = 200, [string]$Content = '{}', [hashtable]$Headers = @{})
    return [pscustomobject]@{ StatusCode = $Status; Content = $Content; Headers = $Headers }
}

function Change-BackupByte {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bytes[10] = $bytes[10] -bxor 1
    [IO.File]::WriteAllBytes($Path, $bytes)
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
        exportCount = 0
        failExportAt = 0
        exportBytes = New-ArchiveFixture
        wrongContentLength = $false
        exportContentType = 'application/octet-stream'
        exportTimeout = $false
        tamperBackupOnVerify = $false
        responseOverrides = @{}
        exportHeaderOverrides = @{}
        onRequest = $null
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
    param($Uri, $Method, $Headers, $Body, $ContentType, $TimeoutSec, $MaximumRedirection, [switch]$SkipHttpErrorCheck, $OutFile, [switch]$PassThru)
    Assert-True ($Uri.StartsWith('https://api.powerbi.com/v1.0/myorg/')) 'Unexpected API host.'
    Assert-True ($Headers.Authorization -eq 'Bearer mock-token-not-a-secret') 'Unexpected token.'
    $path = $Uri.Substring('https://api.powerbi.com/v1.0/myorg/'.Length)
    $global:mock['requests'].Add(@{ method = $Method; path = $path; body = $Body })
    if ($null -ne $global:mock['onRequest']) {
        $null = & $global:mock['onRequest'] $Method $path $OutFile
    }
    $responseKey = "$Method $path"
    if ($global:mock['responseOverrides'].ContainsKey($responseKey) -and
        $global:mock['responseOverrides'][$responseKey].Count -gt 0) {
        $override = $global:mock['responseOverrides'][$responseKey].Dequeue()
        if ($null -ne $override) {
            if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
                [IO.File]::WriteAllText($OutFile, $override.Content)
            }
            return $override
        }
    }
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
    } elseif ($Method -eq 'GET' -and $path -match "^groups/$sourceId/reports/([^/]+)/Export\?downloadType=(IncludeModel|LiveConnect)$") {
        Assert-True (-not [string]::IsNullOrWhiteSpace($OutFile) -and $PassThru) 'Export must stream to local file with response headers.'
        $global:mock['exportCount']++
        if ($global:mock['exportCount'] -eq $global:mock['failExportAt']) {
            [IO.File]::WriteAllText($OutFile, '{"error":{"code":"ExportNotSupported"}}')
            return [pscustomobject]@{ StatusCode = 403; Content = '{"error":{"code":"ExportNotSupported"}}'; Headers = @{} }
        }
        [IO.File]::WriteAllBytes($OutFile, $global:mock['exportBytes'])
        if ($global:mock['exportTimeout']) { throw [TimeoutException]::new('Mock export timeout') }
        $length = $global:mock['exportBytes'].Length
        if ($global:mock['wrongContentLength']) { $length++ }
        $exportHeaders = @{
            'Content-Type' = @($global:mock['exportContentType'])
            'Content-Length' = @([string]$length)
        }
        foreach ($header in $global:mock['exportHeaderOverrides'].GetEnumerator()) {
            if ($null -eq $header.Value) {
                $exportHeaders.Remove($header.Key)
            } else {
                $exportHeaders[$header.Key] = $header.Value
            }
        }
        return [pscustomobject]@{
            StatusCode = 200
            Content = $null
            Headers = $exportHeaders
        }
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
        if ($global:mock['tamperBackupOnVerify']) {
            $savedState = Get-Content -LiteralPath $global:mock['statePath'] -Raw | ConvertFrom-Json -AsHashtable
            foreach ($backup in $savedState['backups'].Values) {
                Add-Content -LiteralPath $backup['path'] -Value 'tampered'
            }
        }
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
    $backupDirectory = Join-Path $testRoot "$Name-backups"
    $global:mock['statePath'] = $statePath
    $parameters = @{ SourceWorkspace = 'Lama'; TargetWorkspace = 'Baru'; StatePath = $statePath; BackupDirectory = $backupDirectory }
    $script:testCount++
    try {
        & $Body
        Write-Host "PASS: $Name"
    } catch {
        $failure = "${Name}: $($_.Exception.Message)"
        $script:failures.Add($failure)
        Write-Host "FAIL: $failure"
    }
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
        Assert-True ($global:mock['exportCount'] -eq 0 -and -not (Test-Path -LiteralPath $backupDirectory)) 'Preview cannot export or create backup files.'
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
        Assert-True (@($beforeDelete | Where-Object { $_['method'] -eq 'GET' -and $_['path'] -match "^groups/$sourceId/reports/[^/?]+$" }).Count -eq 2) 'All sources rechecked before first DELETE.'
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
    Test-Case 'backup-files-manifest-and-order' {
        $global:mock['sourceReports'] += @{ id = $secondReportId; name = 'Other'; datasetId = $datasetId }
        $null = & $migrationScript @parameters -Apply
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($saved['backups'].Count -eq 2) 'All selected backups recorded.'
        foreach ($id in @($reportId, $secondReportId)) {
            $backup = $saved['backups'][$id]
            Assert-True ($backup['downloadType'] -eq 'IncludeModel' -and $backup['reportId'] -eq $id) 'Default export mode and ID mapping.'
            Assert-True ((Get-FileHash -LiteralPath $backup['path'] -Algorithm SHA256).Hash -eq $backup['sha256']) 'Backup hash matches saved bytes.'
            Assert-True ((Get-Item -LiteralPath $backup['path']).Length -eq $backup['sizeBytes']) 'Backup length matches manifest.'
            $manifestPath = Join-Path (Split-Path $backup['path'] -Parent) 'backup-manifest.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
            Assert-True ($manifest['reports'].Count -eq 2 -and $manifest['sourceWorkspaceId'] -eq $sourceId) 'Standalone manifest covers batch.'
        }
        $firstClone = $global:mock['requests'].FindIndex([Predicate[object]]{ param($request) $request['method'] -eq 'POST' })
        $beforeClone = @($global:mock['requests'] | Select-Object -First $firstClone)
        Assert-True (@($beforeClone | Where-Object { $_['path'] -match '/Export\?' }).Count -eq 2) 'All exports before first clone.'
        Assert-True (@(Get-ChildItem -LiteralPath $backupDirectory -Recurse -File -Filter '*.partial').Count -eq 0) 'No partial backup left.'
    }
    Test-Case 'last-backup-fails-no-mutation' {
        $global:mock['sourceReports'] += @{ id = $secondReportId; name = 'Other'; datasetId = $datasetId }
        $global:mock['failExportAt'] = 2
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'HTTP 403'
        Assert-True ($global:mock['postCount'] -eq 0 -and $global:mock['deleteCount'] -eq 0) 'Later backup failure prevents all mutation.'
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($saved['reports'].Count -eq 0 -and $saved['backups'].Count -eq 1) 'Successful earlier backup recorded without cloning.'
        Assert-True (@(Get-ChildItem -LiteralPath $backupDirectory -Recurse -File -Filter '*.partial').Count -eq 0) 'Failed download partial cleaned.'
        $global:mock['failExportAt'] = 0
        $null = & $migrationScript @parameters -Mode Move -Apply
        Assert-True ($global:mock['postCount'] -eq 2 -and $global:mock['deleteCount'] -eq 2) 'Retry after backup failure completes migration.'
    }
    Test-Case 'backup-new-snapshot-without-overwrite' {
        $null = & $migrationScript @parameters -Apply
        $firstState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $firstPath = $firstState['backups'][$reportId]['path']
        $null = & $migrationScript @parameters -Apply
        $secondState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($firstPath -ne $secondState['backups'][$reportId]['path'] -and (Test-Path -LiteralPath $firstPath)) 'New Apply preserves previous PBIX snapshot.'
        Assert-True ($global:mock['exportCount'] -eq 2 -and $global:mock['postCount'] -eq 1) 'Refresh backup without clone replay.'
    }
    Test-Case 'explicit-liveconnect-backup' {
        $null = & $migrationScript @parameters -BackupDownloadType LiveConnect -Apply
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($saved['backups'][$reportId]['downloadType'] -eq 'LiveConnect') 'Explicit LiveConnect mode recorded.'
        Assert-True (@($global:mock['requests'] | Where-Object { $_['path'] -match '/Export\?downloadType=LiveConnect$' }).Count -eq 1) 'Explicit API downloadType.'
    }
    Test-Case 'backup-length-mismatch' {
        $global:mock['wrongContentLength'] = $true
        Assert-Throws { & $migrationScript @parameters -Apply } 'Content-Length'
        Assert-True ($global:mock['postCount'] -eq 0 -and $global:mock['deleteCount'] -eq 0) 'Incomplete length blocks mutation.'
    }
    Test-Case 'backup-empty-file' {
        $global:mock['exportBytes'] = [byte[]]@()
        Assert-Throws { & $migrationScript @parameters -Apply } 'Backup lokal kosong'
        Assert-True ($global:mock['postCount'] -eq 0) 'Empty export cannot pass.'
    }
    Test-Case 'backup-non-pbix-response' {
        $global:mock['exportContentType'] = 'application/json'
        Assert-Throws { & $migrationScript @parameters -Apply } 'bukan file PBIX'
        Assert-True ($global:mock['postCount'] -eq 0) 'JSON response cannot become successful backup.'
    }
    Test-Case 'backup-export-stub-rejected' {
        $global:mock['exportBytes'] = New-ArchiveFixture -EntryName 'ExportStubInfo'
        Assert-Throws { & $migrationScript @parameters -Apply } 'tidak memiliki bagian Report'
        Assert-True ($global:mock['postCount'] -eq 0) 'ZIP export stub cannot count as full backup.'
    }
    Test-Case 'backup-report-directory-only-rejected' {
        $global:mock['exportBytes'] = New-ArchiveFixture -EntryName 'Report/'
        Assert-Throws { & $migrationScript @parameters -Apply } 'tidak memiliki bagian Report'
        Assert-True ($global:mock['postCount'] -eq 0) 'A Report directory without report files is insufficient.'
    }
    Test-Case 'backup-corrupt-zip' {
        $global:mock['exportBytes'] = [Text.Encoding]::UTF8.GetBytes('truncated archive')
        Assert-Throws { & $migrationScript @parameters -Apply } 'Central Directory|InvalidData|archive'
        Assert-True ($global:mock['postCount'] -eq 0) 'Corrupted export cannot pass.'
    }
    Test-Case 'backup-export-timeout-cleanup' {
        $global:mock['exportTimeout'] = $true
        Assert-Throws { & $migrationScript @parameters -Apply } 'export timeout'
        Assert-True ($global:mock['postCount'] -eq 0 -and $global:mock['exportCount'] -eq 1) 'Timeout cannot silently continue or replay.'
        Assert-True (@(Get-ChildItem -LiteralPath $backupDirectory -Recurse -File -Filter '*.partial').Count -eq 0) 'Timed-out partial cleaned.'
    }
    Test-Case 'backup-tamper-before-move-delete' {
        $global:mock['tamperBackupOnVerify'] = $true
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'Integritas backup.*gagal'
        Assert-True ($global:mock['deleteCount'] -eq 0 -and $global:mock['sourceReports'].Count -eq 1) 'Tampered backup cannot authorize source deletion.'
    }
    Test-Case 'resume-missing-source-needs-valid-backup' {
        $global:mock['lostDeleteResponse'] = $true
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'lost DELETE'
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Remove-Item -LiteralPath $saved['backups'][$reportId]['path']
        $global:mock['lostDeleteResponse'] = $false
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'Backup lokal tidak ditemukan'
        Assert-True ($global:mock['exportCount'] -eq 1 -and $global:mock['deleteCount'] -eq 1) 'Missing source cannot be backed up by replaying deletion/export.'
    }
    Test-Case 'legacy-state-live-source-backup' {
        $null = & $migrationScript @parameters -Apply
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $saved.Remove('backups')
        $saved | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath
        $null = & $migrationScript @parameters -Mode Move -Apply
        Assert-True ($global:mock['exportCount'] -eq 2 -and $global:mock['postCount'] -eq 1) 'Legacy state with source obtains backup and reuses clone.'
    }
    Test-Case 'legacy-state-missing-source-blocked' {
        $null = & $migrationScript @parameters -Mode Move -Apply
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $saved.Remove('backups')
        $saved | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'Backup.*belum ada'
        Assert-True ($global:mock['deleteCount'] -eq 1) 'Legacy state cannot claim missing source backed up.'
    }
    Test-Case 'null-json-is-not-source-absence' {
        $global:mock['leaveSourceAfterDelete'] = $true
        Set-ResponseSequence -Method GET -Path "groups/$sourceId/reports/$reportId" -Responses @(
            $null
            (New-MockResponse -Content 'null')
        )
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'Respons JSON.*tidak valid'
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($saved['reports'][$reportId]['status'] -eq 'DeleteRequested') 'HTTP 200 null cannot become SourceDeleted.'
        Assert-True ($global:mock['sourceReports'].Count -eq 1) 'Source still present after malformed confirmation.'
    }
    Test-Case 'invalid-target-collection-blocks-migration' {
        $global:mock['targetReports'] = @(@{ id = $secondReportId; name = 'Sales'; datasetId = $datasetId })
        Set-ResponseSequence -Method GET -Path "groups/$targetId/reports" -Responses @(
            (New-MockResponse -Content '{"value":{}}')
        )
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'Respons daftar report.*tidak valid'
        Assert-True ($global:mock['exportCount'] -eq 0 -and $global:mock['postCount'] -eq 0 -and $global:mock['deleteCount'] -eq 0) 'Malformed collection cannot hide conflicts.'
    }
    Test-Case 'invalid-target-row-blocks-migration' {
        Set-ResponseSequence -Method GET -Path "groups/$targetId/reports" -Responses @(
            (New-MockResponse -Content ('{"value":[{"id":"' + $secondReportId + '"}]}'))
        )
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'Respons daftar report.*tidak valid'
        Assert-True ($global:mock['exportCount'] -eq 0 -and $global:mock['postCount'] -eq 0) 'Missing name cannot be treated as no conflict.'
    }
    Test-Case 'state-invalid-json-blocks-migration' {
        Set-Content -LiteralPath $statePath -Value '{"reports":'
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'JSON|ConvertFrom'
        Assert-True ($global:mock['exportCount'] -eq 0 -and $global:mock['postCount'] -eq 0) 'Corrupt journal cannot start migration.'
    }
    Test-Case 'state-invalid-backups-shape' {
        $null = & $migrationScript @parameters -Apply
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $saved['backups'] = @('invalid')
        $saved | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'Format backups.*tidak valid'
        Assert-True ($global:mock['postCount'] -eq 1 -and $global:mock['deleteCount'] -eq 0) 'Invalid backup metadata stops Move.'
    }
    Test-Case 'resume-backup-mode-mismatch' {
        $null = & $migrationScript @parameters -Mode Move -BackupDownloadType LiveConnect -Apply
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'metadata/downloadType tidak cocok'
        Assert-True ($global:mock['exportCount'] -eq 1 -and $global:mock['deleteCount'] -eq 1) 'LiveConnect backup cannot silently satisfy IncludeModel request.'
    }
    Test-Case 'resume-backup-same-length-different-hash' {
        $null = & $migrationScript @parameters -Mode Move -Apply
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $backup = $saved['backups'][$reportId]
        Change-BackupByte -Path $backup['path']
        Assert-True ((Get-Item -LiteralPath $backup['path']).Length -eq $backup['sizeBytes']) 'Changed fixture retains exact byte length.'
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'Integritas backup.*gagal'
        Assert-True ($global:mock['deleteCount'] -eq 1) 'Same-size corruption cannot pass SHA256 validation.'
    }
    Test-Case 'backup-without-content-length' {
        $global:mock['exportHeaderOverrides']['Content-Length'] = $null
        $result = @(& $migrationScript @parameters -Apply)
        Assert-True ($result[0].status -eq 'Verified') 'Valid streamed backup works without optional Content-Length.'
    }
    Test-Case 'backup-malformed-content-length' {
        $global:mock['exportHeaderOverrides']['Content-Length'] = @('unknown')
        Assert-Throws { & $migrationScript @parameters -Apply } 'Content-Length'
        Assert-True ($global:mock['postCount'] -eq 0) 'Malformed declared length cannot be ignored.'
    }
    Test-Case 'backup-zip-media-type' {
        $global:mock['exportContentType'] = 'application/zip; charset=binary'
        $result = @(& $migrationScript @parameters -Apply)
        Assert-True ($result[0].status -eq 'Verified') 'Documented ZIP export media type with parameters is accepted.'
    }
    foreach ($httpStatus in @(500, 502, 503, 504)) {
        Test-Case "export-transient-http-$httpStatus" {
            $exportPath = "groups/$sourceId/reports/$reportId/Export?downloadType=IncludeModel"
            Set-ResponseSequence -Method GET -Path $exportPath -Responses @(
                (New-MockResponse -Status $httpStatus -Content '{"error":"temporary"}')
                (New-MockResponse -Status $httpStatus -Content '{"error":"temporary"}')
                $null
            )
            $result = @(& $migrationScript @parameters -Apply)
            Assert-True ($result[0].status -eq 'Verified') 'Transient export error can recover.'
            Assert-True (($global:mock['sleeps'] -join ',') -eq '2,4') 'GET export backoff is bounded and exponential.'
            Assert-True (@($global:mock['requests'] | Where-Object { $_['path'] -eq $exportPath }).Count -eq 3) 'Exactly two retry requests.'
            Assert-True (@(Get-ChildItem -LiteralPath $backupDirectory -Recurse -File -Filter '*.partial').Count -eq 0) 'Retry does not leave partial error response.'
        }
    }
    foreach ($httpStatus in @(202, 400, 503)) {
        Test-Case "clone-unexpected-http-$httpStatus" {
            Set-ResponseSequence -Method POST -Path "groups/$sourceId/reports/$reportId/Clone" -Responses @(
                (New-MockResponse -Status $httpStatus)
            )
            Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } "HTTP $httpStatus"
            $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
            Assert-True ($saved['reports'][$reportId]['status'] -eq 'CloneRequested') 'Rejected/uncertain POST remains reviewable.'
            Assert-True (@($global:mock['requests'] | Where-Object { $_['method'] -eq 'POST' }).Count -eq 1 -and $global:mock['deleteCount'] -eq 0) 'Never retry POST or delete after unexpected response.'
        }
    }
    Test-Case 'clone-invalid-returned-id' {
        Set-ResponseSequence -Method POST -Path "groups/$sourceId/reports/$reportId/Clone" -Responses @(
            (New-MockResponse -Content '{"id":"not-a-guid","name":"Sales"}')
        )
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'tidak mengembalikan ID valid'
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($saved['reports'][$reportId]['status'] -eq 'CloneRequested' -and $global:mock['deleteCount'] -eq 0) 'Invalid clone ID cannot mark Created or permit DELETE.'
    }
    foreach ($missingField in @('id', 'name', 'datasetId')) {
        Test-Case "target-missing-$missingField" {
            $global:mock['missingTargetField'] = $missingField
            $global:mock['onRequest'] = {
                param($method, $path, $outFile)
                if ($method -eq 'GET' -and $path -match "^groups/$targetId/reports/[^/?]+$") {
                    $report = $global:mock['targetReports'][0].Clone()
                    $report.Remove($global:mock['missingTargetField'])
                    Set-ResponseSequence -Method GET -Path $path -Responses @(
                        (New-MockResponse -Content ($report | ConvertTo-Json -Compress))
                    )
                }
            }
            Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'Verifikasi report.*gagal'
            $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
            Assert-True ($saved['reports'][$reportId]['status'] -eq 'Created' -and $global:mock['deleteCount'] -eq 0) 'Missing target identity cannot be verified or deleted.'
        }
    }
    Test-Case 'delete-transient-error-is-not-retried' {
        Set-ResponseSequence -Method DELETE -Path "groups/$sourceId/reports/$reportId" -Responses @(
            (New-MockResponse -Status 503)
        )
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'HTTP 503'
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($saved['reports'][$reportId]['status'] -eq 'DeleteRequested') 'Transient DELETE remains pending.'
        Assert-True (@($global:mock['requests'] | Where-Object { $_['method'] -eq 'DELETE' }).Count -eq 1 -and $global:mock['sleeps'].Count -eq 0) 'GET retry policy must not replay DELETE.'
    }
    Test-Case 'backup-storage-file-instead-of-folder' {
        Set-Content -LiteralPath $backupDirectory -Value 'occupied path'
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'file|directory|path'
        Assert-True ($global:mock['exportCount'] -eq 0 -and $global:mock['postCount'] -eq 0 -and $global:mock['deleteCount'] -eq 0) 'Storage failure stops before cloud mutations.'
        $releasedLock = [IO.File]::Open("$statePath.lock", [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $releasedLock.Dispose()
    }
    Test-Case 'backup-manifest-write-failure' {
        $global:mock['onRequest'] = {
            param($method, $path, $outFile)
            if ($path -match '/Export\?' -and $null -ne $outFile) {
                $null = [IO.Directory]::CreateDirectory((Join-Path (Split-Path $outFile -Parent) 'backup-manifest.json.tmp'))
            }
        }
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'directory|Access|path'
        Assert-True ($global:mock['postCount'] -eq 0 -and $global:mock['deleteCount'] -eq 0) 'Manifest write failure stops mutation.'
        Assert-True (@(Get-ChildItem -LiteralPath $backupDirectory -Recurse -File -Filter '*.pbix').Count -eq 1) 'Completed backup is retained on journal failure.'
        Assert-True (-not (Test-Path -LiteralPath $statePath)) 'No successful state claimed after manifest failure.'
    }
    Test-Case 'backup-corruption-between-deletions' {
        $global:mock['sourceReports'] += @{ id = $secondReportId; name = 'Other'; datasetId = $datasetId }
        $global:mock['tamperDeletePath'] = "groups/$sourceId/reports/$reportId"
        $global:mock['onRequest'] = {
            param($method, $path, $outFile)
            if ($method -eq 'DELETE' -and $path -eq $global:mock['tamperDeletePath']) {
                $saved = Get-Content -LiteralPath $global:mock['statePath'] -Raw | ConvertFrom-Json -AsHashtable
                Change-BackupByte -Path $saved['backups'][$secondReportId]['path']
            }
        }
        Assert-Throws { & $migrationScript @parameters -Mode Move -Apply } 'Integritas backup.*gagal'
        Assert-True ($global:mock['deleteCount'] -eq 1 -and $global:mock['sourceReports'][0]['id'] -eq $secondReportId) 'Later corrupted backup blocks its own DELETE.'
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($saved['reports'][$reportId]['status'] -eq 'SourceDeleted' -and $saved['reports'][$secondReportId]['status'] -eq 'Verified') 'Partial deletion remains accurately journaled.'
        $global:mock['onRequest'] = $null
        $null = & $migrationScript @parameters -Mode Move -Apply
        Assert-True ($global:mock['postCount'] -eq 2 -and $global:mock['deleteCount'] -eq 2) 'Explicit resume refreshes remaining backup without cloning again.'
    }
    if ($failures.Count -gt 0) {
        throw "$($failures.Count) of $testCount unit tests failed:`n$($failures -join "`n")"
    }
    Write-Host "All $testCount tests passed. No live API was called."
} finally {
    Remove-Variable -Name mock -Scope Global
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
