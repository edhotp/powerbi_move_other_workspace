#requires -Version 7.0
<#
.SYNOPSIS
Copies or moves Power BI reports between workspaces on the same capacity.
.DESCRIPTION
Read-only preview by default. Use -Apply to execute. Copy retains source
reports; Move deletes them only after all selected targets are verified.
Both modes retain original semantic models and never change capacity.
Uses interactive user login through MicrosoftPowerBIMgmt.Profile 1.3.84+.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceWorkspace,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetWorkspace,

    [guid[]]$ReportIds,

    [ValidateSet('Copy', 'Move')]
    [string]$Mode = 'Copy',

    [switch]$Apply,

    [string]$StatePath = (Join-Path $PSScriptRoot 'migration-state.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$apiRoot = 'https://api.powerbi.com/v1.0/myorg'

function Get-PowerBIHeaders {
    $headers = Get-PowerBIAccessToken -ErrorAction Stop
    if ($headers -isnot [System.Collections.IDictionary] -or
        [string]$headers['Authorization'] -notmatch '^Bearer \S+$') {
        throw 'Respons token sesi Power BI tidak valid. Login ulang menggunakan akun pengguna yang memiliki akses workspace.'
    }
    return $headers
}

function Invoke-PowerBIApi {
    param(
        [ValidateSet('GET', 'POST', 'DELETE')]
        [string]$Method,
        [string]$Path,
        [System.Collections.IDictionary]$Body,
        [switch]$AllowNotFound
    )
    for ($attempt = 0; $attempt -le 3; $attempt++) {
        $request = @{
            Uri = "$script:apiRoot/$Path"
            Method = $Method
            Headers = Get-PowerBIHeaders
            TimeoutSec = 120
            MaximumRedirection = 0
            SkipHttpErrorCheck = $true
        }
        if ($null -ne $Body) {
            $request['ContentType'] = 'application/json; charset=utf-8'
            $request['Body'] = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20 -Compress))
        }
        # A lost POST response may still have created a report. Never replay it.
        $response = Invoke-WebRequest @request
        $status = [int]$response.StatusCode
        if ($status -eq 200) {
            if ($Method -eq 'DELETE') { return }
            return $response.Content | ConvertFrom-Json -AsHashtable
        }
        if ($Method -eq 'GET' -and $AllowNotFound -and $status -eq 404) { return $null }
        if ($Method -eq 'GET' -and $attempt -lt 3 -and $status -in @(429, 500, 502, 503, 504)) {
            $delay = [int][Math]::Pow(2, $attempt + 1)
            if ($response.Headers.ContainsKey('Retry-After')) {
                $seconds = 0
                if ([int]::TryParse([string]($response.Headers['Retry-After'] | Select-Object -First 1), [ref]$seconds)) {
                    $delay = [Math]::Max($delay, $seconds)
                }
            }
            Write-Warning "GET ${Path}: HTTP $status. Coba lagi setelah $delay detik."
            Start-Sleep -Seconds $delay
            continue
        }
        throw "Power BI API gagal: $Method $Path, HTTP $status. $($response.Content)"
    }
}

function Get-PowerBIWorkspaces {
    $skip = 0
    do {
        $page = Invoke-PowerBIApi -Method GET -Path ('groups?$top=100&$skip={0}' -f $skip)
        if (-not $page.ContainsKey('value')) {
            throw 'Respons daftar workspace tidak memiliki value.'
        }
        $items = @($page['value'])
        $items
        $skip += $items.Count
    } while ($items.Count -eq 100)
}

function Resolve-Workspace {
    param([object[]]$Workspaces, [string]$Identifier)
    $id = [guid]::Empty
    if ([guid]::TryParse($Identifier, [ref]$id)) {
        $matches = @($Workspaces | Where-Object { $_['id'] -eq $id.ToString() })
    } else {
        $matches = @($Workspaces | Where-Object { $_['name'] -eq $Identifier })
    }
    if ($matches.Count -ne 1) {
        throw "Workspace '$Identifier' ditemukan $($matches.Count) kali. Gunakan ID yang unik dan cek akses akun."
    }
    return $matches[0]
}

function Save-MigrationState {
    $temporaryPath = "$script:resolvedStatePath.tmp"
    try {
        $state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
        [IO.File]::Move($temporaryPath, $script:resolvedStatePath, $true)
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath
        }
    }
}

function Assert-ReportBinding {
    param(
        [System.Collections.IDictionary]$Report,
        [string]$ExpectedId,
        [string]$ExpectedName,
        [string]$ExpectedDataset
    )
    if ($Report['id'] -ne $ExpectedId -or $Report['name'] -cne $ExpectedName -or $Report['datasetId'] -ne $ExpectedDataset) {
        throw "Verifikasi report '$ExpectedName' gagal: ID, nama, atau datasetId berbeda. Cek state dan report tujuan; jangan clone ulang otomatis."
    }
}

$resolvedStatePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StatePath)
$lock = $null
try {
    if ($Apply) {
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($resolvedStatePath))
        # Keep this file so concurrent processes always lock the same file.
        $lock = [IO.File]::Open("$resolvedStatePath.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    foreach ($commandName in @('Connect-PowerBIServiceAccount', 'Get-PowerBIAccessToken')) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($null -eq $command -or
            ($null -ne $command.Module -and $command.Module.Version -lt [version]'1.3.84')) {
            throw 'Pasang/update modul autentikasi: Install-Module MicrosoftPowerBIMgmt.Profile -MinimumVersion 1.3.84 -Scope CurrentUser -Force. Kemudian gunakan sesi PowerShell baru.'
        }
    }
    Write-Host 'Login interaktif Power BI: pilih akun pengguna yang memiliki akses ke kedua workspace.'
    $null = Connect-PowerBIServiceAccount -Environment Public -ErrorAction Stop
    $workspaces = @(Get-PowerBIWorkspaces)
    $source = Resolve-Workspace -Workspaces $workspaces -Identifier $SourceWorkspace
    $target = Resolve-Workspace -Workspaces $workspaces -Identifier $TargetWorkspace
    if ($source['id'] -eq $target['id']) {
        throw 'Workspace asal dan tujuan harus berbeda.'
    }
    foreach ($workspace in @($source, $target)) {
        $capacity = [guid]::Empty
        if ($workspace['isOnDedicatedCapacity'] -ne $true -or
            -not [guid]::TryParse([string]$workspace['capacityId'], [ref]$capacity) -or $capacity -eq [guid]::Empty) {
            throw "Workspace '$($workspace['name'])' belum memiliki capacityId dedicated yang valid."
        }
        if ($workspace['isReadOnly'] -ne $false) {
            throw "Workspace '$($workspace['name'])' tidak memiliki akses tulis untuk akun ini."
        }
    }
    if ($source['capacityId'] -ne $target['capacityId']) {
        throw 'capacityId workspace asal dan tujuan berbeda. Script ini tidak mengubah penempatan capacity.'
    }

    $state = @{
        schemaVersion = 1
        sourceWorkspaceId = $source['id']
        targetWorkspaceId = $target['id']
        capacityId = $source['capacityId']
        reports = @{}
    }
    if (Test-Path -LiteralPath $resolvedStatePath) {
        $state = Get-Content -LiteralPath $resolvedStatePath -Raw | ConvertFrom-Json -AsHashtable
        if ($state['schemaVersion'] -ne 1 -or $state['sourceWorkspaceId'] -ne $source['id'] -or
            $state['targetWorkspaceId'] -ne $target['id'] -or $state['capacityId'] -ne $source['capacityId'] -or
            $state['reports'] -isnot [System.Collections.IDictionary]) {
            throw 'State tidak cocok dengan pasangan workspace/capacity atau formatnya tidak valid. Gunakan StatePath khusus untuk pasangan ini.'
        }
    }

    $sourceResponse = Invoke-PowerBIApi -Method GET -Path "groups/$($source['id'])/reports"
    $targetResponse = Invoke-PowerBIApi -Method GET -Path "groups/$($target['id'])/reports"
    if (-not $sourceResponse.ContainsKey('value') -or -not $targetResponse.ContainsKey('value')) {
        throw 'Respons daftar report tidak memiliki value.'
    }
    $reports = @($sourceResponse['value'])
    $targetReports = @($targetResponse['value'])
    $liveSourceIds = @($reports | ForEach-Object { $_['id'] })
    if ($Mode -eq 'Move') {
        foreach ($entry in $state['reports'].GetEnumerator()) {
            if ($entry.Value['status'] -in @('DeleteRequested', 'SourceDeleted') -and $entry.Key -notin $liveSourceIds) {
                $reports += @{
                    id = $entry.Key
                    name = $entry.Value['name']
                    datasetId = $entry.Value['datasetId']
                }
            }
        }
    }
    if ($null -ne $ReportIds -and $ReportIds.Count -gt 0) {
        $availableIds = @($reports | ForEach-Object { $_['id'] })
        foreach ($requested in $ReportIds) {
            if ($requested -eq [guid]::Empty -or $requested.ToString() -notin $availableIds) {
                throw "Report ID '$requested' tidak ditemukan di workspace asal."
            }
        }
        $selectedIds = @($ReportIds | ForEach-Object { $_.ToString() })
        $reports = @($reports | Where-Object { $_['id'] -in $selectedIds })
    }
    if ($reports.Count -eq 0) {
        throw 'Tidak ada report untuk dimigrasikan.'
    }
    $duplicateNames = @($reports | Group-Object { $_['name'] } | Where-Object Count -gt 1)
    if ($duplicateNames.Count -gt 0) {
        throw 'Ada report asal dengan nama sama. Pilih satu per nama menggunakan -ReportIds.'
    }

    $plan = @(
        foreach ($report in $reports) {
            $reportId = [string]$report['id']
            if ([string]::IsNullOrWhiteSpace($report['name']) -or
                [string]::IsNullOrWhiteSpace($report['datasetId']) -or
                ($report.ContainsKey('reportType') -and $report['reportType'] -ne 'PowerBIReport')) {
                throw "Report '$($report['name'])' bukan Power BI report dengan datasetId. RDL/paginated dan report tanpa datasetId tidak didukung script ini."
            }
            $existing = @($targetReports | Where-Object { $_['name'] -eq $report['name'] })
            $action = 'Clone'
            if ($state['reports'].ContainsKey($reportId)) {
                $record = $state['reports'][$reportId]
                if ($record['name'] -cne $report['name'] -or $record['datasetId'] -ne $report['datasetId']) {
                    throw "Report asal '$($report['name'])' berubah sejak pencatatan state. Tinjau manual."
                }
                if ($record['status'] -eq 'CloneRequested') {
                    throw "Hasil clone '$($report['name'])' belum pasti. Cek workspace tujuan dan state sebelum melanjutkan; POST tidak diulang."
                }
                if ($record['status'] -notin @('Created', 'Verified', 'DeleteRequested', 'SourceDeleted')) {
                    throw "Status state '$($record['status'])' tidak dikenal."
                }
                if ($record['status'] -in @('DeleteRequested', 'SourceDeleted') -and $Mode -ne 'Move') {
                    throw "Report '$($report['name'])' memiliki proses Move di state. Gunakan -Mode Move untuk melanjutkan; Copy tidak menghapus sumber."
                }
                if ($record['status'] -eq 'SourceDeleted' -and $reportId -in $liveSourceIds) {
                    throw "Report asal '$($report['name'])' muncul lagi setelah SourceDeleted. Tinjau manual; sumber tidak dihapus ulang."
                }
                if ($existing.Count -ne 1 -or $existing[0]['id'] -ne $record['targetReportId']) {
                    throw "Report tujuan '$($report['name'])' hilang atau konflik dengan state. Tinjau manual."
                }
                Assert-ReportBinding -Report $existing[0] -ExpectedId $record['targetReportId'] -ExpectedName $record['name'] -ExpectedDataset $record['datasetId']
                $action = 'VerifyExisting'
            } elseif ($existing.Count -gt 0) {
                throw "Nama '$($report['name'])' sudah ada di tujuan tetapi tidak tercatat di state. Script tidak menimpa atau menganggapnya hasil migrasi."
            }
            @{
                sourceReportId = $reportId
                name = [string]$report['name']
                datasetId = [string]$report['datasetId']
                action = $action
                sourcePresent = ($reportId -in $liveSourceIds)
                sourceAction = if ($Mode -eq 'Copy') { 'Keep' } elseif ($reportId -in $liveSourceIds) { 'Delete' } else { 'ConfirmDeleted' }
            }
        }
    )
    Write-Host "Asal: $($source['name']) [$($source['id'])]"
    Write-Host "Tujuan: $($target['name']) [$($target['id'])]"
    Write-Host "Capacity sama: $($source['capacityId'])"
    Write-Host "Mode: $Mode"
    Write-Warning 'Semantic model tetap di lokasi asal. Jangan hapus workspace/model asal; akses pengguna ke model tetap diperlukan.'
    if ($Mode -eq 'Move') {
        Write-Warning 'MOVE akan menghapus report asal setelah semua tujuan lolos verifikasi API. URL/sharing/app lama dapat terputus; verifikasi API bukan uji visual/RLS.'
    }
    $plan | ForEach-Object { [pscustomobject]$_ } | Format-Table name, sourceReportId, datasetId, action, sourceAction | Out-Host
    if (-not $Apply) {
        Write-Host 'PREVIEW saja: tidak ada report dibuat atau dihapus. Tambahkan -Apply untuk menjalankan.'
        $plan | ForEach-Object { [pscustomobject]$_ }
        return
    }

    foreach ($item in $plan) {
        $reportId = $item['sourceReportId']
        if ($item['action'] -eq 'Clone') {
            $state['reports'][$reportId] = @{
                name = $item['name']
                datasetId = $item['datasetId']
                targetReportId = $null
                status = 'CloneRequested'
                updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            }
            Save-MigrationState
            $created = Invoke-PowerBIApi -Method POST -Path "groups/$($source['id'])/reports/$reportId/Clone" -Body @{
                name = $item['name']
                targetWorkspaceId = $target['id']
            }
            $createdId = [guid]::Empty
            if (-not [guid]::TryParse([string]$created['id'], [ref]$createdId) -or $createdId -eq [guid]::Empty) {
                throw "Clone '$($item['name'])' tidak mengembalikan ID valid. Cek tujuan; jangan ulang POST."
            }
            $state['reports'][$reportId]['targetReportId'] = $createdId.ToString()
            $state['reports'][$reportId]['status'] = 'Created'
            Save-MigrationState
        }
        $record = $state['reports'][$reportId]
        $verified = Invoke-PowerBIApi -Method GET -Path "groups/$($target['id'])/reports/$($record['targetReportId'])"
        Assert-ReportBinding -Report $verified -ExpectedId $record['targetReportId'] -ExpectedName $record['name'] -ExpectedDataset $record['datasetId']
        if ($record['status'] -notin @('DeleteRequested', 'SourceDeleted')) {
            $record['status'] = 'Verified'
        }
        $record['webUrl'] = $verified['webUrl']
        $record['updatedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('o')
        Save-MigrationState
        Write-Host "Verified: $($record['name']) [$($record['targetReportId'])]"
    }
    if ($Mode -eq 'Move') {
        # Check every source before the first deletion, not just before its own deletion.
        foreach ($item in $plan | Where-Object { $_['sourcePresent'] }) {
            $currentSource = Invoke-PowerBIApi -Method GET -Path "groups/$($source['id'])/reports/$($item['sourceReportId'])"
            Assert-ReportBinding -Report $currentSource -ExpectedId $item['sourceReportId'] -ExpectedName $item['name'] -ExpectedDataset $item['datasetId']
        }
        foreach ($item in $plan) {
            $record = $state['reports'][$item['sourceReportId']]
            $sourcePath = "groups/$($source['id'])/reports/$($item['sourceReportId'])"
            if ($record['status'] -ne 'SourceDeleted') {
                $record['status'] = 'DeleteRequested'
                $record['updatedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('o')
                Save-MigrationState
                if ($item['sourcePresent']) {
                    Invoke-PowerBIApi -Method DELETE -Path $sourcePath
                }
            }
            $remainingSource = Invoke-PowerBIApi -Method GET -Path $sourcePath -AllowNotFound
            if ($null -ne $remainingSource) {
                throw "Penghapusan report asal '$($item['name'])' belum terkonfirmasi. Tinjau state dan jalankan ulang -Mode Move; sumber tidak dihapus ulang otomatis."
            }
            $record['status'] = 'SourceDeleted'
            $record['updatedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('o')
            Save-MigrationState
            Write-Host "Moved: $($record['name']); report asal sudah tidak ditemukan melalui API."
        }
    }
    Write-Host "Selesai ($Mode): $($plan.Count) report terverifikasi melalui API. State: $resolvedStatePath"
    Write-Warning 'Verifikasi API bukan pemeriksaan visual/data/RLS. Buka report sebagai pengguna tujuan sebelum cutover.'
    foreach ($item in $plan) {
        [pscustomobject]$state['reports'][$item['sourceReportId']]
    }
} finally {
    if ($null -ne $lock) {
        $lock.Dispose()
    }
}
